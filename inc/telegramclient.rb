class TelegramClient

    attr_reader :jid, :login, :online, :auth_state, :me
    attr_accessor :timezone

    # tdlib configuration, shared within all instances #
    def self.configure(params) 
        @@loglevel = params['loglevel'] || Logger::DEBUG
        @@content_path = params['content_path'] || '/tmp'
        @@content_link = params['content_link'] || 'https://localhost/tg_media'
        @@content_upload_prefix = params["content_upload_prefix"] || 'https://localhost/upload/'
        TD.configure do |config|
            config.lib_path = params['path'] || 'lib/' # we hope it's here
            config.client.api_id = params['api_id'] || '50322' # telegram app. from debian repositories
            config.client.api_hash = params['api_hash'] || '9ff1a639196c0779c86dd661af8522ba' # telegram app. from debian repositories
            config.client.device_model = params['useragent'] || 'Zhabogram'
            config.client.application_version = params['version'] || '1.0' # hmm...
            config.client.use_test_dc = params['use_test_dc'] || false
            config.client.system_version = '42' # I think I have permission to hardcode The Ultimate Question of Life, the Universe, and Everything?..
            config.client.use_file_database = true # wow
            config.client.use_message_database = true # such library 
            config.client.use_chat_info_database = true # much options
            config.client.enable_storage_optimizer = false # ...
        end
        TD::Api.set_log_verbosity_level(params['verbosity'] || 1)
    end
    
    # instance initialization #
    def initialize(xmpp, jid, login)
        return if not @@loglevel # call .configure() first    
        @logger = Logger.new(STDOUT); @logger.level = @@loglevel; @logger.progname = '[TelegramClient: %s/%s]' % [jid, login] # create logger
        @logger.info 'Starting Telegram client..'
        @xmpp = xmpp # XMPP stream 
        @jid = jid # user JID 
        @timezone = '-00:00' # default timezone is UTC
        @login = login # telegram login 
        @me = nil # self telegram profile
        @online = nil # we do not know
        @auth_state = 'nil' # too.
        @cache = {chats: {}, users: {}, photos: {}} # cache 
    end
    
    # initialize and connect telegram client #
    def connect()
        return if @client and @client.ready? 
        @logger.info 'Connecting to Telegram network..' 
        @client = TD::Client.new(database_directory: 'sessions/' + @jid, files_directory: 'sessions/' + @jid + '/files/') # create telegram client instance
        @client.on(TD::Types::Update::AuthorizationState) do |update| self.auth_handler(update) end # register auth update handler 
        @client.on(TD::Types::Update::File) do |update| self.file_handler(update);  end # register file handler 
        @client.on(TD::Types::Update::NewMessage) do |update| self.message_handler(update);  end # register new message update handler 
        @client.on(TD::Types::Update::MessageContent) do |update| self.message_edited_handler(update) end # register msg edited handler
        @client.on(TD::Types::Update::DeleteMessages) do |update| self.message_deleted_handler(update) end # register msg del handler
        @client.on(TD::Types::Update::NewChat) do |update| self.new_chat_handler(update) end # register new chat handler 
        @client.on(TD::Types::Update::User) do |update| self.user_handler(update) end # new user update? 
        @client.on(TD::Types::Update::UserStatus) do |update| self.status_update_handler(update) end # register status handler 
        @client.connect() 
        return true
    end

    # disconnect and destroy telegram client #
    def disconnect(logout = false)
        return if not @client 
        @logger.info 'Disconnecting..'
        @cache[:chats].each_key do |chat_id| @xmpp.presence(@jid, chat_id.to_s, :unavailable) end # send offline presences
        (logout) ? @client.log_out : @client.dispose # logout if needed  
        @client = nil
        @online = false
    end
    
    
    ###########################################
    ## Callback handlers #####################
    ###########################################

    # authorization handler #
    def auth_handler(update)
        @logger.debug 'Authorization state changed: %s' % update.authorization_state
        @auth_state = update.authorization_state.class.name

        case update.authorization_state
        # auth stage 0: specify login #
        when TD::Types::AuthorizationState::WaitPhoneNumber
            @logger.info 'Logging in..'
            @client.set_authentication_phone_number(@login)
         # auth stage 1: wait for authorization code #    
        when TD::Types::AuthorizationState::WaitCode
            @logger.info 'Waiting for authorization code..'
            @xmpp.message(@jid, nil, 'Please, enter authorization code via /code 12345')
        # auth stage 2: wait for 2fa passphrase #
        when TD::Types::AuthorizationState::WaitPassword
            @logger.info 'Waiting for 2FA password..'
            @xmpp.message(@jid, nil, 'Please, enter 2FA passphrase via /password 12345')
        # authorization successful -- indicate that client is online and retrieve contact list  #
        when TD::Types::AuthorizationState::Ready 
            @logger.info 'Authorization successful!'
            @client.get_me().then { |user| @me = user }.wait 
            @client.get_chats(limit=9999) 
            @logger.info "Contact list updating finished"
            @xmpp.presence(@jid, nil, :subscribe)
            @xmpp.presence(@jid, nil, nil, nil, "Logged in as %s" % @login)
            @online = true
        # closing session: sent offline presences to XMPP user #
        when TD::Types::AuthorizationState::Closing
            @logger.info 'Closing session..'
            self.disconnect()
        # session closed gracefully
        when TD::Types::AuthorizationState::Closed
            @logger.info 'Session closed.'
            self.disconnect()
        end        
    end

    # message from telegram network handler # 
    def message_handler(update, show_date = false)
        return if update.message.is_outgoing and update.message.sending_state.instance_of? TD::Types::MessageSendingState::Pending # ignore self outgoing messages

        @logger.debug 'Got NewMessage update'
        @logger.debug update.message.to_json
        @logger.info 'New message from Telegram chat %s' % update.message.chat_id

        # message content
        prefix = []
        content = update.message.content

        # file handling 
        file = case content
            when TD::Types::MessageContent::Sticker then [content.sticker.sticker, content.sticker.emoji + '.webp']
            when TD::Types::MessageContent::VoiceNote then [content.voice_note.voice, 'voice message (%i seconds).oga' % content.voice_note.duration]
            when TD::Types::MessageContent::VideoNote then [content.video_note.video, 'video message (%i seconds).mp4' % content.video_note.duration]
            when TD::Types::MessageContent::Animation then [content.animation.animation, content.animation.file_name + '.mp4' ]
            when TD::Types::MessageContent::Photo then [content.photo.sizes[-1].photo, content.photo.id + '.jpg']
            when TD::Types::MessageContent::Audio then [content.audio.audio, content.audio.file_name] 
            when TD::Types::MessageContent::Video then [content.video.video, content.video.file_name] 
            when TD::Types::MessageContent::Document then [content.document.document, content.document.file_name]
        end
        
        # text handling
        text = case content
            when TD::Types::MessageContent::BasicGroupChatCreate, TD::Types::MessageContent::SupergroupChatCreate then "has created chat"
            when TD::Types::MessageContent::ChatJoinByLink then "joined chat via invite link"
            when TD::Types::MessageContent::ChatAddMembers then "invited %s" % self.format_contact(message.content.member_user_ids.first)
            when TD::Types::MessageContent::ChatDeleteMember then "kicked %s" % self.format_contact(update.message.content.user_id)
            when TD::Types::MessageContent::PinMessage then "pinned message: %s" % self.format_message(update.message.chat_id, content.message_id)
            when TD::Types::MessageContent::ChatChangeTitle then "chat title set to: %s" % update.message.content.title.to_s
            when TD::Types::MessageContent::Location then "coordinates: %s | https://www.google.com/maps/search/%s,%s/" %  [content.location.latitude, content.location.longitude]
            when TD::Types::MessageContent::Photo, TD::Types::MessageContent::Audio, TD::Types::MessageContent::Video, TD::Types::MessageContent::Document then content.caption.text
            when TD::Types::MessageContent::Text then content.text.text
            when TD::Types::MessageContent::VoiceNote then content.caption.text
            when TD::Types::MessageContent::VideoNote then ''
            else "unknown message type %s" % update.message.content.class
        end
        
        # download file if needed
        @client.download_file(file[0].id) if file and not file[0].local.is_downloading_completed

        # forwards, replies and message id..
        prefix << DateTime.strptime((update.message.date+Time.now.getlocal(@timezone).utc_offset).to_s,'%s').strftime("%d %b %Y %H:%M:%S") if show_date # show date if its 
        prefix << (update.message.is_outgoing ? '➡ ' : '⬅ ') + update.message.id.to_s  # message direction
        prefix << "%s" % self.format_contact(update.message.sender_user_id) if update.message.chat_id < 0 # show sender in group chats 
        prefix << "fwd: %s" % self.format_contact(update.message.forward_info.sender_user_id) if update.message.forward_info.instance_of? TD::Types::MessageForwardInfo::MessageForwardedFromUser  # fwd  from user 
        prefix << "fwd: %s%s" % [self.format_contact(update.message.forward_info.chat_id), (update.message.forward_info.author_signature != '') ? " (%s)"%update.message.forward_info.author_signature : ''] if update.message.forward_info.instance_of? TD::Types::MessageForwardInfo::MessageForwardedPost  # fwd from chat 
        prefix << "reply: %s" % self.format_message(update.message.chat_id, update.message.reply_to_message_id, false) if update.message.reply_to_message_id.to_i != 0 # reply to
        prefix << "file: %s" % self.format_file(file[0], file[1]) if file 
        prefix = prefix.join(' | ')
        prefix += (update.message.chat_id < 0 and text and text != "") ? "\n" : '' # \n if it is groupchat and message is not empty
        prefix += (update.message.chat_id > 0 and text and text != "") ? " | " : ''

        # OTR support
        text = prefix + text unless text.start_with? '?OTR' 

        # read message & send it to xmpp
        @client.view_messages(update.message.chat_id, [update.message.id], force_read: true)
        @xmpp.message(@jid, update.message.chat_id.to_s, text)
    end
    
    # new chat update -- when tg client discovers new chat #
    def new_chat_handler(update)   
        @logger.debug 'Got NewChat update'
        @logger.debug update.to_json
        self.process_chat_info(update.chat.id)
    end

    # user -- something changed in user data #
    def user_handler(update)   
        @logger.debug 'Got User update'
        @logger.debug update.to_json
        self.process_user_info(update.user.id)
    end

    # edited msg #
    def message_edited_handler(update)
        @logger.debug 'Got MessageEdited update'
        @logger.debug update.to_json
        
        # formatting
        text = "✎ %s | %s" % [update.message_id.to_s, update.new_content.text.text.to_s]
        @xmpp.message(@jid, update.chat_id.to_s, text)        
    end

    # deleted msg #
    def message_deleted_handler(update)
        @logger.debug 'Got MessageDeleted update'
        @logger.debug update.to_json
        return if not update.is_permanent
        text = "✗ %s |" % update.message_ids.join(',')
        @xmpp.message(@jid, update.chat_id.to_s, text)                
    end
    
    # status update handler #
    def status_update_handler(update)
        @logger.debug 'Got new StatusUpdate'
        @logger.debug update.to_json
        return if update.user_id == @me.id # ignore self statuses
        self.process_status_update(update.user_id, update.status, false)
    end


    # file msg -- symlink to download path #
    def file_handler(update)
        @logger.debug 'Got File update'
        @logger.debug update.to_json
        if update.file.local.is_downloading_completed then
            source =  update.file.local.path.to_s
            target = self.format_file(update.file, update.file.local.path, true)
            @logger.debug 'Downloading of <%s> completed! Created link to <%s>' % [source, target] 
            File.symlink(source, target)
        end
    end
    
    ###########################################
    ## LooP handlers #########################
    ###########################################
    
    # processing authorization #
    def process_auth(typ, auth_data)
        @logger.info "Authorizing with :%s.." % typ
        @client.check_authentication_code(auth_data) if typ == '/code'
        @client.check_authentication_password(auth_data) if typ == '/password'
    end

    # /command #
    def process_command(chat_id, text)
        arg = text[0..2] == '/s/' ? ['/sed', text[3..-1]] : text.split 
    
        # .. 
        if arg[1] and arg[1][0] == '@' then @client.search_public_chat(arg[1][1..-1]).then {|c| resolve = c}.wait end # try to resolve @username from second arg #
        if arg[1].to_i < 0 then resolve = self.process_chat_info(arg[1].to_i, false) end # try to resolve chat_id/user_id from second arg 
        if arg[1].to_i > 0 then resolve = self.process_user_info(arg[1].to_i) end # try to resolve user_id from second arg 
    
        # command... 
        response = nil
        current = @cache[:chats][chat_id] # current chat 
        resolve = resolve || nil  # resolved chat or nil
        chat = resolve || current # resolved chat or current
        case arg[0] 
            when '/info'            then response = self.format_contact(chat.id) # print information
            when '/add'             then (chat.id > 0) ? self.process_chat_info(chat.id, true) : @client.join_chat(chat.id).wait # add contact 
            when '/join'            then @client.join_chat_by_invite_link(arg[1]).wait if arg[1][0..3] == 'http' # join chat by link 
            when '/secret'          then @client.create_new_secret_chat(chat.id).wait if chat.id > 0 # new secret chat
            when '/group'           then @client.create_new_basic_group_chat(resolve.id, arg[2]).it if resolve and arg[2]
            when '/supergroup'      then @client.create_new_supergroup_chat(arg[1], arg[2]).wait if arg[2]
            when '/channel'         then @client.create_new_supergroup_chat(arg[1], arg[2], is_channel: true).wait if arg[2]
            when '/invite'          then @client.add_chat_member(current.id, resolve.id).wait if resolve
            when '/kick'            then @client.set_chat_member_status(current, resolve.id, TD::Types::ChatMemberStatus::Left.new()).wait if resolve
            when '/ban'             then @client.set_chat_member_status(current.id, resolve.id, TD::Types::ChatMemberStatus::Banned.new(banned_until_date: (arg[1]) ? Time.now.getutc.to_i + arg[1].to_i * 3600 : 0)).wait if resolve
            when '/block'           then @client.block_user(current.id).wait
            when '/unblock'         then @client.unblock_user(current.id).wait
            when '/members'         then members = []
                                         response = "- Members of chat %s -\n\n" % current.title
                                         @client.search_chat_members(current.id,filter:TD::Types::ChatMembersFilter::Members.new).then{ |m| members+=m.members }.wait if current.type.instance_of? TD::Types::ChatType::BasicGroup  # basic 
                                         @client.get_supergroup_members(current.type.supergroup_id).then{|m| members+=m.members }.wait if current.type.instance_of? TD::Types::ChatType::Supergroup # super
                                         members.each do |user| response += "%s | Role: %s \n" % [self.format_contact(user.user_id, true, false), user.status.class] end 
            when '/leave','/delete' then @client.close_chat(current.id).wait
                                         @client.leave_chat(current.id) if current.type.instance_of? TD::Types::ChatType::BasicGroup or current.type.instance_of? TD::Types::ChatType::Supergroup
                                         @client.close_secret_chat(current.type.secret_chat_id).wait if current.type.instance_of? TD::Types::ChatType::Secret
                                         @client.delete_chat_history(current.id, true).wait
                                         @xmpp.presence(@jid, current.id.to_s, :unsubscribed) 
                                         @xmpp.presence(@jid, current.id.to_s, :unavailable)
                                         @cache[:chats].delete(current.id) if @cache[:chats].key? current.id
                                         @cache[:users].delete(current.id) if @cache[:users].key? current.id
            when '/sed'             then id, edited = nil, nil 
                                         sed = arg[1].split('/') 
                                         @client.search_chat_messages(current.id, 0, 1, sender_user_id: @me.id, filter: TD::Types::SearchMessagesFilter::Empty.new).then{|m| id,edited = m.messages[0].id,m.messages[0].content.text.text.to_s}.wait
                                         @client.edit_message_text(current.id,id,TD::Types::InputMessageContent::Text.new(text: {text: edited.gsub(Regexp.new(sed[0]),sed[1]), entities: []},disable_web_page_preview: false, clear_draft: true)).wait if id
            when '/d'               then id = arg[1].to_i
                                         @client.search_chat_messages(current.id, 0, 1, sender_user_id: @me.id, filter: TD::Types::SearchMessagesFilter::Empty.new).then {|m| id = m.messages[0].id }.wait if id == 0
                                         @client.delete_messages(current.id, [id], true)
            when '/search'          then count = arg[1] || 10
                                         query = arg[2] || nil
                                         @client.search_chat_messages(current.id, 0, count, query: query, filter: TD::Types::SearchMessagesFilter::Empty.new).then {|msgs| 
                                            msgs.messages.reverse.each do |msg| self.message_handler(TD::Types::Update::NewMessage.new(message: msg, disable_notification: false, contains_mention: false), true) end
                                         }.wait
            when '/setusername'     then @client.set_username(arg[1] || '') 
            when '/setname'         then @client.set_name(arg[1] || '', arg[2] || '')
            when '/setbio'          then @client.set_bio(arg[1..99].join(' '))
            when '/setpassword'     then old_password, new_password = arg[1], arg[2]
                                         old_password = '' if old_password == 'nil'
                                         new_password = nil if new_password == 'nil'
                                         @client.set_password(old_password, new_password: new_password)
            when '/dump'            then response = current.to_json
            else response = 'Unknown command. 
            
                /s/mitsake/mistake/ — Edit last message
                /d — Delete last message
                
                /info id — Information about user/chat by its id
                /add @username or id — Create conversation with specified user or chat id
                /join chat_link or id — Join chat by its link or id

                /secret @username — Create "secret chat" with specified user
                /group @username groupname — Create group chat named groupname with @username
                /supergroup name description — Create supergroup chat
                /channel name description — Create channel

                /members — Supergroup members
                /search count query — Search in chat history

                /invite @username — Invite @username to current chat 
                /kick @username — Remove @username from current chat 
                /ban @username [hours] — Ban @username in current chat for [hours] hrs or forever if [hours] not specified
                /block — Blacklistscurrent user
                /unblock — Remove current user from blacklist
                /delete — Delete current chat
                /leave — Leave current chat

                /setusername username — Set username
                /setname First Last — Set name
                /setbio Bio — Set bio
                /setpassword old new — Set 2FA password (use "nil" for no password") 
                ' 
        end
        
        @xmpp.message(@jid, chat_id.to_s, response) if response
    end
    
    # processing outgoing message from queue #
    def process_outgoing_msg(chat_id, text)
        @logger.info 'Sending message to Telegram chat %s...' % chat_id

        # processing /commands #
        return if not @cache[:chats].key? chat_id # null chat
        return self.process_command(chat_id, text) if text[0] == '/'
        
        # handling replies #
        reply_to = 0
        if text[0] == '>' and text.match(Regexp.new /^>( )?[0-9]{10,20}/) then 
            text = text.split("\n")
            reply_to = text[0].scan(/\d+/).first.to_i
            text = text.drop(1).join("\n")
        end

        # handling files received from xmpp #
        message = TD::Types::InputMessageContent::Text.new(:text => { :text => text, :entities => []}, :disable_web_page_preview => false, :clear_draft => true )
        message = TD::Types::InputMessageContent::Document.new(document: TD::Types::InputFile::Remote.new(id: text), caption: { :text => '', :entities => []}) if text.start_with? @@content_upload_prefix  
        
        # send message and mark chat as read #
        @client.send_message(chat_id, message, reply_to_message_id: reply_to)
    end

    # update users information and save it to cache #
    def process_chat_info(chat_id, subscription = true)
        @logger.debug 'Updating chat id %s..' % chat_id.to_s
        @client.get_chat(chat_id).then { |chat|    
            @cache[:chats][chat_id] = chat   # cache chat 
            @client.download_file(chat.photo.small.id).then{|f| @cache[:photos][chat_id] = f}.wait if chat.photo # download userpic
            @xmpp.presence(@jid, chat_id.to_s, :subscribe, nil, nil, chat.title.to_s) if subscription # send subscription request
            self.process_status_update(chat_id, chat.title.to_s, true) if chat.id < 0 # groups presence 
        }.wait
        return @cache[:chats][chat_id] if @cache[:chats].key? chat_id 
    end
    
    # update user info in cache and sync status to roster if needed #
    def process_user_info(user_id)
        @logger.debug 'Updating user id %s..' % user_id
        @client.get_user(user_id).then { |user| 
            @cache[:users][user_id] = user  # add to cache 
            @client.get_user_full_info(user_id).then{ |bio| @cache[:chats][user_id].attributes[:client_data] = bio.bio }.wait
            self.process_status_update(user_id, user.status, true) # status update
        }.wait
        return @cache[:users][user_id] if @cache[:users].key? user_id  
    end

    # sync statuses with XMPP roster 
    def sync_status()   
        @logger.debug "Syncing statuses with roster.."
        @cache[:chats].each_value do |chat| self.process_status_update(chat.id, (chat.id > 0 and @cache[:users].include? chat.id) ? @cache[:users][chat.id].status : chat.title.to_s, true) end 
    end
    
    # convert telegram status to XMPP one
    def process_status_update(user_id, status, immed = true)
        @logger.debug "Processing status update for user id %s.." % user_id.to_s 
        xmpp_show, xmpp_status, xmpp_photo = nil 
        case status 
            when TD::Types::UserStatus::Online then xmpp_show, xmpp_status = nil, "Online"
            when TD::Types::UserStatus::Offline then xmpp_show, xmpp_status = (Time.now.getutc.to_i - status.was_online.to_i < 3600) ? :away : :xa, DateTime.strptime((status.was_online+Time.now.getlocal(@timezone).utc_offset).to_s,'%s').strftime("Last seen at %H:%M %d/%m/%Y")
            when TD::Types::UserStatus::Recently then xmpp_show, xmpp_status = :dnd, "Last seen recently"
            when TD::Types::UserStatus::LastWeek then xmpp_show, xmpp_status = :unavailable, "Last seen last week"
            when TD::Types::UserStatus::LastMonth then xmpp_show, xmpp_status = :unavailable, "Last seen last month"
            else xmpp_show, xmpp_status = :chat, status
        end

        xmpp_photo = self.format_file(@cache[:photos][user_id], 'image.jpg', true) if @cache[:photos].include? user_id
        xmpp_photo = (File.exist?  xmpp_photo.to_s) ? Digest::SHA1.hexdigest(IO.binread(xmpp_photo)) : nil
        # ...
        return @xmpp.presence(@jid, user_id.to_s, nil, xmpp_show, xmpp_status, nil, xmpp_photo, immed) 
    end
    
    # get contact information (for vcard). 
    def get_contact_info(chat_id)
        return if not @cache[:chats].key? chat_id  # no such chat #
    
        username, firstname, lastname, phone, bio, userpic = nil 
        title  = @cache[:chats][chat_id].title # <FN>

        # user information 
        if @cache[:users].key? chat_id then # its an user
            firstname = @cache[:users][chat_id].first_name # <N/GIVEN>
            lastname = @cache[:users][chat_id].last_name # <N/FAMILY>
            username = @cache[:users][chat_id].username  # <NICKNAME>
            phone = @cache[:users][chat_id].phone_number  # <TEL>
            bio = @cache[:chats][chat_id].client_data # <DESC>
            userpic = self.format_file(@cache[:photos][chat_id], 'image.jpg', true) if @cache[:photos].include? chat_id
            userpic = (File.exist? userpic.to_s) ? Base64.encode64(IO.binread(userpic)) : nil
        end
        
        # ..
        return title, username, firstname, lastname, phone, bio, userpic
    end
    
    # resolve id by @username (or just return id)
    def resolve_username(username)
        resolved = username 
        if username[0] == '@' then @client.search_public_chat(username[1..-1]).then {|chat| resolved = '@' + chat.id.to_s}.wait end 
        if  username[0..3] == 'http' or username[0..3] == 't.me' then @client.join_chat_by_invite_link(username) end 
        return resolved 
    end
    
    ###########################################
    ## Format functions #######################
    ###########################################
    # format tg user name #
    def format_contact(id, show_id = false, resolve = true)
        fmt = ''
        if id < 0 then # its chat 
            fmt = (@cache[:chats].key? id) ? "%s" % @cache[:chats][id].title : "%s" % id 
        elsif id > 0 then # its user 
            self.process_user_info(id) if not @cache[:users].key? id and resolve
            user = @cache[:users][id] if @cache[:users].key? id 
            fmt += user.first_name if user and user.first_name != ''
            fmt += " " + user.last_name if user and user.last_name != ''
            fmt += " (@%s)" % user.username if user and user.username != '' 
            fmt += " (%s)" % id if (user and user.username == '') or show_id
        else
            fmt = "unknown (%s)" % id
        end

        return fmt
    end

    # format reply# 
    def format_message(chat_id, message_id, full = true)
        text = ''
        @client.get_message(chat_id, message_id).then { |message| text = message.content.text.text }.wait 
        return (not full) ? "%s >> %s.." % [message_id, text.split("\n")[0]] : "%s | %s " % [message_id, text]
    end

    def format_file(file, filename, local = false)
        if local then return "%s/%s%s" % [@@content_path, Digest::SHA256.hexdigest(file.remote.id), File.extname(filename)] end
        return "%s (%d kbytes) | %s/%s%s" % [filename, file.size/1024, @@content_link,  Digest::SHA256.hexdigest(file.remote.id), File.extname(filename).to_s] 
    end

    # state functions #
    def online?() @online end    
    def tz_set?() return @timezone != '-00:00' end
end
