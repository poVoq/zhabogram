HELP_GATE_CMD = %q{Available commands: 
    /login phone — sign in
    /logout — sign out
    /code — check one-time code
    /password — check 2fa password
    /setusername username — update @username
    /setname first last — update name
    /setbio — update about
    /setpassword [old] [new] — set or remove password
    /config [param] [value] — view or update configuration options
    Configuration options
    timezone 00:00 — adjust timezone for Telegram user statuses
}

HELP_CHAT_CMD= %q{Available commands:
    /d [n] — delete your last message(s)
    /s regexp replace — edit your last message
    /add @username — add @username to your chat list
    /join https://t.me/invite_link — join to chat via invite link
    /group title — create groupchat «title» with current user
    /supergroup title description — create new supergroup «title» with «description»
    /channel title description — create new channel «title» with «description»
    /secret — create secretchat with current user
    /search string [limit] — search <string> in current chat
    /history [limit] — get last [limit] messages from current chat
    /block — blacklist current user
    /unblock — unblacklist current user
    /invite id or @username — add user to current chat
    /kick id or @username — remove user from current chat
    /ban id or @username [hours] — restrict @username from current chat for [hours] or forever
    /leave — leave current chat
    /close — close current secret chat
    /delete — delete current chat from chat list
    /members [query] — search members [by optional query] in current chat (requires admin rights)
}

class TelegramClient

    attr_reader :session, :state
    @@config = {loglevel: :debug, verbosity: 2, lib_path: 'lib/', client: {api_id: 50322, api_hash: '9ff1a639196c0779c86dd661af8522ba', use_chat_info_database: false}, content: {path:'',link:'',upload:''}}  # defaults 

    ## configure tdlib (when valid tdlib params specified) or zhabogram
    def self.configure(**config) 
        @@config = @@config.merge(config)  
        TD.config.update(config[:tdlib])
        TD::Api.set_log_verbosity_level(@@config[:tdlib_verbosity])
    end
    
    ## initialize telegram client instance (xmpp = XMPP stream, jid = user's jid , login = user's telegram login (for now, it is phone number)
    def initialize(xmpp, jid, **session)
        @logger    = Logger.new(STDOUT, level: @@config[:loglevel], progname: 'TelegramClient: %s | %s' % [jid, session[:login]] )
        @xmpp      = xmpp
        @jid       = jid
        @session   = session
        @cache     = {chats: {nil => []}, users: {}}
    end
    
    ## connect telegram client 
    def connect()
        return if self.online? # already connected.
        @logger.warn 'Connecting to Telegram network..' 
        @telegram = TD::Client.new(database_directory: 'sessions/' + @jid, files_directory: 'sessions/' + @jid + '/files/')
        @telegram.on(TD::Types::Update::AuthorizationState) do |u| @logger.debug(u);  self.update_authorizationstate(u)  end
        @telegram.on(TD::Types::Update::User)               do |u| @logger.debug(u);  self.update_user(u)                end  
        @telegram.on(TD::Types::Update::UserStatus)         do |u| @logger.debug(u);  self.update_userstatus(u)          end 
        @telegram.on(TD::Types::Update::NewChat)            do |u| @logger.debug(u);  self.update_newchat(u)             end  
        @telegram.on(TD::Types::Update::NewMessage)         do |u| @logger.debug(u);  self.update_newmessage(u)          end  
        @telegram.on(TD::Types::Update::MessageContent)     do |u| @logger.debug(u);  self.update_messagecontent(u)      end  
        @telegram.on(TD::Types::Update::DeleteMessages)     do |u| @logger.debug(u);  self.update_deletemessages(u)      end  
        @telegram.on(TD::Types::Update::File)               do |u| @logger.debug(u);  self.update_file(u)                end
        @telegram.connect()
    end
    
    ## disconnect telegram client 
    def disconnect()
        return unless self.online?  # already disconnected
        @logger.warn 'Disconnecting from Telegram network..'
        @cache[:chats].each_key do |chat| @xmpp.send_presence(@jid, chat, :unavailable) end # we're offline (unsubscribe if logout)
        @telegram.dispose()
        @telegram = nil
    end
    
    ## online?
    def online? 
        @telegram and @telegram.alive?
    end
    
    #########################################################################
    # telegram updates handlers #############################################
    #########################################################################
    
    ##  authorization state change 
    def update_authorizationstate(update)
        @state = update.authorization_state.class.name
        case update.authorization_state
        when TD::Types::AuthorizationState::WaitPhoneNumber # stage 0: set login 
            @logger.warn 'Logging in..'
            @telegram.set_authentication_phone_number(@session[:login]) if @session[:login]
            @xmpp.send_message(@jid, nil, 'Please, enter your Telegram login via /login 12345') if not @session[:login]
        when TD::Types::AuthorizationState::WaitCode # stage 1: wait for auth code 
            @logger.warn 'Waiting for authorization code..'
            @xmpp.send_message(@jid, nil, 'Please, enter authorization code via /code 12345')
        when TD::Types::AuthorizationState::WaitPassword # stage 2: wait for 2fa
            @logger.warn 'Waiting for 2FA password..'
            @xmpp.send_message(@jid, nil, 'Please, enter 2FA passphrase via /password 12345')
        when TD::Types::AuthorizationState::Ready  # stage 3: auth completed
            @session[:login] ||= @me.phone_number 
            @logger.warn 'Authorization successful!'
            @telegram.get_me.then{|me| @me = me}.wait
            @telegram.get_chats(limit=999).wait
            @xmpp.send_presence(@jid, nil, nil, nil, "Logged in %s" % @session[:login])
        end
    end

    ##  message received  
    def update_newmessage(update, show_date = false)
        return if update.message.is_outgoing and update.message.sending_state.instance_of? TD::Types::MessageSendingState::Pending # ignore self outgoing messages
        @logger.warn 'New message from chat %s' % update.message.chat_id

        content, prefix = update.message.content, []
        text = case content # text 
            when TD::Types::MessageContent::Sticker then content.sticker.emoji
            when TD::Types::MessageContent::BasicGroupChatCreate, TD::Types::MessageContent::SupergroupChatCreate then "has created chat"
            when TD::Types::MessageContent::ChatJoinByLink then "joined chat via invite link"
            when TD::Types::MessageContent::ChatAddMembers then "invited %s" % self.format_contact(message.content.member_user_ids.first)
            when TD::Types::MessageContent::ChatDeleteMember then "kicked %s" % self.format_contact(update.message.content.user_id)
            when TD::Types::MessageContent::PinMessage then "pinned message: %s" % self.format_message(update.message.chat_id, content.message_id)
            when TD::Types::MessageContent::ChatChangeTitle then "chat title set to: %s" % update.message.content.title
            when TD::Types::MessageContent::Location then "coordinates: %{latitude},%{longitude} | https://www.google.com/maps/search/%{latitude},%{longitude}/" %  content.location.to_h
            when TD::Types::MessageContent::Photo, TD::Types::MessageContent::Audio, TD::Types::MessageContent::Video, TD::Types::MessageContent::Document then content.caption.text
            when TD::Types::MessageContent::Text then content.text.text
            when TD::Types::MessageContent::VoiceNote then content.caption.text
            when TD::Types::MessageContent::VideoNote then ''
            when TD::Types::MessageContent::Animation then ''
            else "unknown message (%s)" % update.message.content.class
        end
        file = case content # file(s)
            when TD::Types::MessageContent::Sticker then [content.sticker.sticker, 'sticker.webp']
            when TD::Types::MessageContent::VoiceNote then [content.voice_note.voice, 'voice note (%i s.).oga' % content.voice_note.duration]
            when TD::Types::MessageContent::VideoNote then [content.video_note.video, 'video note (%i s.).mp4' % content.video_note.duration]
            when TD::Types::MessageContent::Animation then [content.animation.animation, 'animation.mp4' ]
            when TD::Types::MessageContent::Photo then [content.photo.sizes[-1].photo, content.photo.id + '.jpg']
            when TD::Types::MessageContent::Audio then [content.audio.audio, content.audio.file_name] 
            when TD::Types::MessageContent::Video then [content.video.video, 'video' + content.video.file_name + '.mp4'] 
            when TD::Types::MessageContent::Document then [content.document.document, content.document.file_name]
        end
        @telegram.download_file(file[0].id) if file and not file[0].local.is_downloading_completed # download file(s)
        prefix << DateTime.strptime((update.message.date+Time.now.getlocal(@session[:timezone]).utc_offset).to_s,'%s').strftime("%d %b %Y %H:%M:%S") if show_date # show date if its 
        prefix << (update.message.is_outgoing ? '➡ ' : '⬅ ') + update.message.id.to_s  # message direction
        prefix << "%s" % self.format_contact(update.message.sender_user_id) if update.message.chat_id < 0 and update.message.sender_user_id # show sender in group chats 
        prefix << "fwd: %s" % self.format_contact(update.message.forward_info.sender_user_id) if update.message.forward_info.instance_of? TD::Types::MessageForwardInfo::MessageForwardedFromUser  # fwd  from user 
        prefix << "fwd: %s%s" % [self.format_contact(update.message.forward_info.chat_id), (update.message.forward_info.author_signature != '') ? " (%s)"%update.message.forward_info.author_signature : ''] if update.message.forward_info.instance_of? TD::Types::MessageForwardInfo::MessageForwardedPost  # fwd from chat 
        prefix << "reply: %s" % self.format_message(update.message.chat_id, update.message.reply_to_message_id, true) if update.message.reply_to_message_id.to_i != 0 # reply to
        prefix << "file: %s" % self.format_content(file[0], file[1]) if file 
        prefix = prefix.join(' | ')
        prefix += (update.message.chat_id < 0 and text and text != "") ? "\n" : '' # \n if it is groupchat and message is not empty
        prefix += (update.message.chat_id > 0 and text and text != "") ? " | " : ''

        text = prefix + text unless text.start_with? '?OTR'  # OTR support (I do not know why would you need it, seriously)
        @telegram.view_messages(update.message.chat_id, [update.message.id], force_read: true) # mark message as read  
        @xmpp.send_message(@jid, update.message.chat_id, text)  # forward message to XMPP
    end
    
    ##  message content updated
    def update_messagecontent(update)
        text = "✎ %s | %s" % [update.message_id, update.new_content.text.text]
        @xmpp.send_message(@jid, update.chat_id, text)        
    end

    ##  message(s) deleted 
    def update_deletemessages(update)
        text = "✗ %s" % update.message_ids.join(',')
        @xmpp.send_message(@jid, update.chat_id, text) if update.is_permanent
    end
    
    ##  new chat discovered 
    def update_newchat(update)
        @telegram.download_file(update.chat.photo.small.id).wait if update.chat.photo 
        @cache[:chats][update.chat.id] = update.chat
        @xmpp.send_presence(@jid, update.chat.id, :subscribe, nil, nil, update.chat.title.to_s) unless (update.chat.type.instance_of? TD::Types::ChatType::Supergroup and update.chat.type.is_channel and update.chat.last_read_inbox_message_id == 0)
        self.process_status_update(update.chat.id, update.chat.title, :chat) if update.chat.id < 0
    end

    ##  new user discovered 
    def update_user(update)
        @cache[:users][update.user.id] = update.user
        self.process_status_update(update.user.id, update.user.status)
    end

    ##  user status changed
    def update_userstatus(update)
        self.process_status_update(update.user_id, update.status, nil, false)
    end

    ##  file downloaded
    def update_file(update)
        return unless update.file.local.is_downloading_completed # not really
        File.symlink(update.file.local.path, "%s/%s%s" % [@@config[:content][:path], Digest::SHA256.hexdigest(update.file.remote.id), File.extname(update.file.local.path)])
    end

    #########################################################################
    # xmpp to telegram gateway functions ####################################
    #########################################################################

    ##  get user and chat information from cache (or try to retrieve it, if missing)  
    def get_contact(id)
        return unless self.online?  # we're offline.
        @telegram.search_public_chat(id).then{|chat| id = chat.id }.wait if id[0] == '@'
        @telegram.get_user(id).wait if not @cache[:users][id] and (id>0) 
        @telegram.get_chat(id).wait if not @cache[:chats][id]
        return @cache[:chats][id], @cache[:users][id]
    end

    ##  set contact status
    def process_status_update(chat_id, status=nil, show=nil, immed=true) 
        return unless self.online?  # we're offline.
        @logger.info "Status update for %s" % chat_id
        chat, user = self.get_contact(chat_id)
        photo = Digest::SHA1.hexdigest(IO.binread(chat.photo.small.local.path)) if chat and chat.photo and File.exist? chat.photo.small.local.path
        status ||= user.status if user and user.status
        case status
            when nil                              then show, status = :chat, chat ? chat.title : nil
            when TD::Types::UserStatus::Online    then show, status = nil, "Online"
            when TD::Types::UserStatus::Recently  then show, status = :dnd, "Last seen recently"
            when TD::Types::UserStatus::LastWeek  then show, status = :unavailable, "Last seen last week"
            when TD::Types::UserStatus::LastMonth then show, status = :unavailable, "Last seen last month"
            when TD::Types::UserStatus::Empty     then show, status = :unavailable, "Last seen a long time ago"
            when TD::Types::UserStatus::Offline   then show, status = (Time.now.getutc.to_i-status.was_online.to_i<3600) ? :away : :xa, 
                                                                       DateTime.strptime((status.was_online+Time.now.getlocal(@session[:timezone]).utc_offset).to_s,'%s').strftime("Last seen at %H:%M %d/%m/%Y")
        end
        @xmpp.send_presence(@jid, chat_id, nil, show, status, nil, photo, immed) 
    end

    ##  send outgoing message to telegram user  
    def process_outgoing_message(chat_id, text, message_id = nil) 
        return if self.process_command(chat_id, text.split.first, text.split[1..-1]) # try to execute a command (and do not send on success)
        return unless self.online?  # we're offline.
        @logger.warn 'Send message to chat %s' % chat_id
        reply = text.lines[0].scan(/\d+/).first.to_i if text.lines[0] =~ /^> ?[0-9]{10}/  # quotations 
        file = TD::Types::InputFile::Remote.new(id: text) if text.start_with? @@config[:content][:upload]  # attach a file 
        text = TD::Types::FormattedText.new(text: (reply or file) ? text.lines[1..-1].join : text, entities: [])    # remove first line from text
        message = TD::Types::InputMessageContent::Text.new(text: text, disable_web_page_preview: false, clear_draft: false)  # compile our message
        document = TD::Types::InputMessageContent::Document.new(document: file, caption: text)  if file  # we can try to send a document 
        message_id ? @telegram.edit_message_text(chat_id, message_id, message) : @telegram.send_message(chat_id,document||message, reply_to_message_id: reply||0).rescue{|why| @xmpp.send_message(@jid, chat_id,"Message not sent: %s" % why)} 
    end
        
    ##  /commands (some telegram actions)
    def process_command(chat_id, cmd, args)
        chat, user = self.get_contact(chat_id) unless chat_id == 0  # get chat information
        if chat_id == 0 then  # transport commands 
            case cmd
            when '/login'       then @telegram.set_authentication_phone_number(args[0]).then{|_| @session[:login] = args[0]} unless @session[:login]  # sign in
            when '/logout'      then @telegram.log_out().then{|_| @cache[:chats].each_key do |chat| @xmpp.send_presence(@jid, chat, :unsubscribed); @session[:login] = nil end } # sign out
            when '/code'        then @telegram.check_authentication_code(args[0]) # check auth code 
            when '/password'    then @telegram.check_authentication_password(args[0]) # chech auth password
            when '/setusername' then @telegram.set_username(args[0] || '') # set @username
            when '/setname'     then @telegram.set_name(args[0] || '', args[1] || '')   #  set My Name
            when '/setbio'      then @telegram.set_bio(args[0] || '')  # set About
            when '/setpassword' then @telegram.set_password((args[1] ? args[0] : ''), args[1])  # set password
            when '/config'      then @xmpp.send_message(@jid, nil, args[1] ? "%s set to %s" % [args[0], @session.store(args[0].to_sym, args[1])] : @session.map{|attr| "%s is set to %s" % attr}.join("\n")) 
            when '/help'        then @xmpp.send_message(@jid, nil, HELP_GATE_CMD)
            end
            return true # stop executing 
        else  # chat commands
            case cmd
            when '/d'          then @telegram.delete_messages(chat.id, @telegram.search_chat_messages(chat.id, 0, args[0]||1, sender_user_id: @me.id, filter: TD::Types::SearchMessagesFilter::Empty.new).value.messages.map(&:id), true) # delete last message(s)
            when '/s'          then @telegram.search_chat_messages(chat.id, 0, 1, sender_user_id: @me.id, filter: TD::Types::SearchMessagesFilter::Empty.new).value.messages.each do |msg| self.process_outgoing_message(chat.id, msg.content.text.text.to_s.gsub(Regexp.new(args[0]),args[1..-1].join(' ')), msg.id) end # edit last message
            when '/add'        then @telegram.search_public_chat(args[0]).then{|chat| @xmpp.send_presence(@jid, chat.id, :subscribe)}.wait # add @contact 
            when '/join'       then @telegram.join_chat_by_invite_link(args[0])  # join https://t.me/publichat
            when '/supergroup' then @telegram.create_new_supergroup_chat(args[0], args[1..-1].join(' '), is_channel: false) # create new supergroup 
            when '/channel'    then @telegram.create_new_supergroup_chat(args[0], args[1..-1].join(' '), is_channel: true)  # create new channel 
            when '/secret'     then @telegram.create_new_secret_chat(chat.id)  if user   # create secret chat with current user
            when '/group'      then @telegram.create_new_basic_group_chat(chat.id, args[0])  if chat.id > 0  # create group chat with current user 
            when '/block'      then @telegram.block_user(chat.id)  if chat.id > 0 # blacklists current user
            when '/unblock'    then @telegram.unblock_user(chat.id)  if chat.id > 0  # unblacklists current user 
            when '/invite'     then @telegram.add_chat_member(chat.id, (args[0].to_i == 0 ? @telegram.search_public_chat(args[0]).value.id : args[0].to_i)) if chat.id < 0  # invite @username to current groupchat 
            when '/kick'       then @telegram.set_chat_member_status(chat.id, (args[0].to_i == 0 ? @telegram.search_public_chat(args[0]).value.id : args[0].to_i)) if chat.id < 0  # kick @username from current group chat
            when '/ban'        then @telegram.set_chat_member_status(chat.id, (args[0].to_i == 0 ? @telegram.search_public_chat(args[0]).value.id : args[0].to_i), TD::Types::ChatMemberStatus::Banned(banned_until_date: (args[1].to_i > 0 ? Time.now.getutc.to_i+(args[1].to_i*3600) : 0))) if chat.id < 0 # ban @username from current chat [for N hours]
            when '/leave'      then @telegram.leave_chat(chat.id).then{@xmpp.send_presence(@jid, chat_id, :unsubscribed)} if chat.type.instance_of? TD::Types::ChatType::Supergroup or chat.type.instance_of? TD::Types::ChatType::BasicGroup  # leave current chat  
            when '/close'      then @telegram.close_secret_chat(chat.type.secret_chat_id).then{@xmpp.send_presence(@jid, chat_id, :unsubscribed)} if chat.type.instance_of? TD::Types::ChatType::Secret   # close secret chat 
            when '/delete'     then @telegram.delete_chat_history(chat.id, true).then{@xmpp.send_presence(@jid, chat_id, :unsubscribed)} # delete current chat 
            when '/search'     then @telegram.search_chat_messages(chat.id, 0, args[1]||10, query: args[0]||nil, filter: TD::Types::SearchMessagesFilter::Empty.new).value.messages.reverse.each do |msg| @xmpp.send_message(@jid, chat_id, self.format_message(nil,nil,nil,msg)) end # search messages within current chat
            when '/history'    then @telegram.get_chat_history(chat.id, 0, 0, args[0]||10).value.messages.reverse.each do |msg| @xmpp.send_message(@jid, chat_id, self.format_message(nil,nil,msg)) end # get latest entries from history
            when '/members'    then @telegram.search_chat_members(chat.id,9999,query:args[0],filter: TD::Types::ChatMembersFilter::Members.new).then{|members| @xmpp.send_message(@jid, chat_id, (members.members.map do |user| "%s | role: %s" % [self.fmt_chat(user.user_id), user.status.class] end).join("\n")) }  # members list (for admins)
            when '/help'       then @xmpp.send_message(@jid, chat_id, HELP_CHAT_CMD)
            else return # continue executing
            end
            return true # stop executing
        end
    end
    
    #########################################################################
    # formatting functions  #################################################
    #########################################################################
    
    def format_contact(chat_id)
        return if not chat_id or chat_id == 0
        chat, user = self.get_contact(chat_id)
        str = chat_id
        str = "%s (%s)" % [chat.title, chat.id] if chat
        str = "%s %s (%s)" % [user.first_name, user.last_name, (user.username.empty?) ? user.id : user.username] if user
        str = str.gsub('  ', ' ')
        return str
    end

    def format_content(file, fname) 
        str = "%s (%d kbytes) | %s/%s%s" % [fname, file.size/1024, @@config[:content][:link],  Digest::SHA256.hexdigest(file.remote.id), File.extname(fname).to_s] 
        return str 
    end    

    def format_message(chat_id, message_id, preview=false, message=nil)
        message ||= @telegram.get_message(chat_id, message_id).value
        return unless message
        str = "%s | %s | " % [message.id, self.format_contact(message.sender_user_id)]
        str += DateTime.strptime((message.date+Time.now.getlocal(@session[:timezone]).utc_offset).to_s,'%s').strftime("%d %b %Y %H:%M:%S | ") unless preview
        str += (not preview or message.content.text.text.lines.count <= 1) ? message.content.text.text : message.content.text.text.lines.first
        return str
    end

end
