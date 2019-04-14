require 'tdlib-ruby'
require 'digest' 
require 'base64'

class TelegramClient

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
            config.client.use_file_database = false # wow
            config.client.use_message_database = false # such library 
            config.client.use_chat_info_database = false # much options
            config.client.enable_storage_optimizer = false # ...
        end
        TD::Api.set_log_verbosity_level(params['verbosity'] || 1)
    end
    
    # instance initialization #
    def initialize(xmpp, login)
        return if not @@loglevel # call .configure() first
    
        @logger = Logger.new(STDOUT); @logger.level = @@loglevel; @logger.progname = '[TelegramClient: %s/%s]' % [xmpp.user_jid, login] # create logger
        @xmpp = xmpp # our XMPP user session. we will send messages back to Jabber through this instance. 
        @login = login # store tg login 
        @cache = {chats: {}, users: {}, users_fi: {}, unread_msg: {} } # we will store our cache here
        @files_dir = File.dirname(__FILE__) + '/../sessions/' + @xmpp.user_jid + '/files/'

        # spawn telegram client and specify callback handlers 
        @logger.info 'Connecting to Telegram network..'        
        @client = TD::Client.new(database_directory: 'sessions/' + @xmpp.user_jid, files_directory: 'sessions/' + @xmpp.user_jid + '/files/') # create telegram client instance
        @client.on(TD::Types::Update::AuthorizationState) do |update| self.auth_handler(update) end # register auth update handler 
        @client.on(TD::Types::Update::NewMessage) do |update| self.message_handler(update) end # register new message update handler 
        @client.on(TD::Types::Update::MessageContent) do |update| self.message_edited_handler(update) end # register msg edited handler
        @client.on(TD::Types::Update::DeleteMessages) do |update| self.message_deleted_handler(update) end # register msg del handler
        @client.on(TD::Types::Update::File) do |update| self.file_handler(update) end # register file handler 
        @client.on(TD::Types::Update::NewChat) do |update| self.new_chat_handler(update) end # register new chat handler 
        @client.on(TD::Types::Update::User) do |update| self.user_handler(update) end # new user update? 
        @client.on(TD::Types::Update::UserStatus) do |update| self.status_update_handler(update) end # register status handler 
        @client.connect
        
    end
    
    ###########################################
    ## Callback handlers #####################
    ###########################################

    # authorization handler #
    def auth_handler(update)
        @logger.debug 'Authorization state changed: %s' % update.authorization_state

        case update.authorization_state
        # auth stage 0: specify login #
        when TD::Types::AuthorizationState::WaitPhoneNumber
            @logger.info 'Logging in..'
            @client.set_authentication_phone_number(@login)
         # auth stage 1: wait for authorization code #    
        when TD::Types::AuthorizationState::WaitCode
            @logger.info 'Waiting for authorization code..'
            @xmpp.incoming_message(nil, 'Please, enter authorization code via /code 12345')
        # auth stage 2: wait for 2fa passphrase #
        when TD::Types::AuthorizationState::WaitPassword
            @logger.info 'Waiting for 2FA password..'
            @xmpp.incoming_message(nil, 'Please, enter 2FA passphrase via /password 12345')
        # authorization successful -- indicate that client is online and retrieve contact list  #
        when TD::Types::AuthorizationState::Ready 
            @logger.info 'Authorization successful!'
            @client.get_me().then { |user| @me = user }.wait 
            @client.get_chats(limit=9999) 
            @logger.info "Contact list updating finished"
            @xmpp.online!
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
    def message_handler(update)
        @logger.debug 'Got NewMessage update'
        @logger.debug update.message.to_json

        return if not @cache[:chats].key? update.message.chat_id # we do not know about this chat, ignore it
        return if update.message.is_outgoing and update.message.sending_state.instance_of? TD::Types::MessageSendingState::Pending # ignore self outgoing messages
        
        # media? #
        file = nil
        text = ''
        case update.message.content 
        when TD::Types::MessageContent::Photo # photos 
            file = update.message.content.photo.sizes[-1].photo
            text = "%s.jpg (image/jpeg), %d bytes | %s | %s" % [update.message.content.photo.id.to_s, file.size.to_i, self.format_content_link(file.remote.id, 'image.jpg'), update.message.content.caption.text.to_s]
        when TD::Types::MessageContent::Animation  # "gif" (mp4) animations 
            file = update.message.content.animation.animation
            text = "gif: %s | %s" % [update.message.content.animation.file_name, self.format_content_link(file.remote.id, 'video.mp4')]
        when TD::Types::MessageContent::Sticker  # stickers 
            file = update.message.content.sticker.sticker
            text = "sticker: %s | %s" % [update.message.content.sticker.emoji.to_s, self.format_content_link(file.remote.id, 'sticker.webp')]
        when TD::Types::MessageContent::Audio # music files
            file = update.message.content.audio.audio 
            text = "%s (%s), %d bytes | %s | %s" % [update.message.content.audio.file_name.to_s, update.message.content.audio.mime_type.to_s, file.size.to_i, self.format_content_link(file.remote.id, update.message.content.audio.file_name.to_s), update.message.content.caption.text.to_s]
        when TD::Types::MessageContent::Video # video files
            file = update.message.content.video.video 
            text = "%s (%s), %d bytes | %s | %s" % [update.message.content.video.file_name.to_s, update.message.content.video.mime_type.to_s, file.size.to_i, self.format_content_link(file.remote.id, update.message.content.video.file_name.to_s), update.message.content.caption.text.to_s]
        when TD::Types::MessageContent::VoiceNote # voice messages
            file = update.message.content.voice_note.voice
            text = "voice message (%i s.) | %s" % [update.message.content.voice_note.duration, self.format_content_link(file.remote.id, 'voice.oga')]
        when TD::Types::MessageContent::Document # documents 
            file = update.message.content.document.document
            text = "%s (%s), %d bytes | %s | %s" % [update.message.content.document.file_name.to_s, update.message.content.document.mime_type.to_s, file.size.to_i, self.format_content_link(file.remote.id, update.message.content.document.file_name.to_s), update.message.content.caption.text.to_s]
        when TD::Types::MessageContent::ChatJoinByLink # joined member
            text = "joined"
        when TD::Types::MessageContent::ChatAddMembers # add members
            text = "added "
            update.message.content.member_user_ids.each do |member| text = text + self.format_username(member) + ' ' end
        when TD::Types::MessageContent::ChatDeleteMember # kicked member
            text = "removed %s" % self.format_username(update.message.content.user_id)
        when TD::Types::MessageContent::PinMessage # pinned message
            @client.get_message(update.message.chat_id, update.message.content.message_id).then { |message| text = "pinned message: %s" % message.content.text.text.to_s }.wait 
        when TD::Types::MessageContent::ChatChangeTitle # changed chat title
            text = "chat title set to: %s" % update.message.content.title.to_s
        when TD::Types::MessageContent::Location # location
            location = "%s,%s" % [update.message.content.location.latitude.to_s, update.message.content.location.longitude.to_s]
            text = "coordinates: %s | https://www.google.com/maps/search/%s/" %  [location, location]
        when TD::Types::MessageContent::Text # plain text
            text = update.message.content.text.text.to_s
        else
            text = "unknown message type %s" % update.message.content.class
        end 
        @client.download_file(file.id) if file  # download it if already not
                
        # forwards, replies and message id..
        text = "| fwd %s | %s" % [self.format_username(update.message.forward_info.sender_user_id), text] if update.message.forward_info.instance_of? TD::Types::MessageForwardInfo::MessageForwardedFromUser  # fwd  from user 
        text = "| fwd %s(%s) | %s" % [self.format_chatname(update.message.forward_info.chat_id), update.message.forward_info.author_signature.to_s, text] if update.message.forward_info.instance_of? TD::Types::MessageForwardInfo::MessageForwardedPost  # fwd from chat 
        text = "| reply %s | %s" % [self.format_reply(update.message.chat_id, update.message.reply_to_message_id), text] if update.message.reply_to_message_id.to_i != 0 # reply
        text = "%s | %s | %s" % [update.message.id.to_s, self.format_username(update.message.sender_user_id), text] # username/id

        # send and add message id to unreads
        @cache[:unread_msg][update.message.chat_id] = update.message.id
        @xmpp.incoming_message(update.message.chat_id.to_s, text)
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
        text = "[MSG %s EDIT] %s" % [update.message_id.to_s, update.new_content.text.text.to_s]
        @xmpp.incoming_message(update.chat_id.to_s, text)        
    end

    # deleted msg #
    def message_deleted_handler(update)
        @logger.debug 'Got MessageDeleted update'
        @logger.debug update.to_json
        return if not update.is_permanent
        text = "[MSG %s DELETE]" % update.message_ids.join(',')
        @xmpp.incoming_message(update.chat_id.to_s, text)                
    end

    # file msg -- symlink to download path #
    def file_handler(update)
        @logger.debug 'Got File update'
        @logger.debug update.to_json
        if update.file.local.is_downloading_completed then
            fname = update.file.local.path.to_s
            target = "%s/%s%s" % [@@content_path, Digest::SHA256.hexdigest(update.file.remote.id), File.extname(fname)]
            @logger.debug 'Downloading of <%s> completed! Link to <%s>' % [fname, target] 
            File.symlink(fname, target)
        end
    end
    
    # status update handler #
    def status_update_handler(update)
        @logger.debug 'Got new StatusUpdate'
        @logger.debug update.to_json
        return if update.user_id == @me.id # ignore self statuses
        self.process_status_update(update.user_id, update.status)
    end

    
    ###########################################
    ## LooP handlers #########################
    ###########################################
    
    # processing authorization #
    def process_auth(typ, auth_data)
        @logger.debug 'check_authorization with %s..' % typ
        @client.check_authentication_code(auth_data) if typ == '/code'
        @client.check_authentication_password(auth_data) if typ == '/password'
    end

    # /command #
    def process_command(chat_id, text)
        splitted = text.split # splitted[0] = command, splitted[1] = argument
        splitted = ['/sed', text[3..-1]] if text[0..2] == '/s/' # sed-like edit 
        resolved = nil; response = nil

        # if second argument starts with @, try to resolve it
        @client.search_public_chat(splitted[1][1..-1]).then {|chat| resolved = chat}.wait if splitted[1] and splitted[1][0] == '@'

        case splitted[0] 
        when '/add' # open new private chat by its id
            chat = (resolved) ? resolved.id : splitted[1].to_i
            self.process_chat_info(chat) if chat != 0
        when '/join' # join group/supergroup by invite link or by id 
            chat = (resolved) ? resolved.id : splitted[1]
            chat.to_s[0..3] == "http" ? @client.join_chat_by_invite_link(chat).wait : @client.join_chat(chat.to_i).wait
        when '/invite' # invite user to chat
            @client.add_chat_member(chat_id, resolved.id).wait if resolved
        when '/kick' #  removes user from chat
            @client.set_chat_member_status(chat_id, resolved.id, TD::Types::ChatMemberStatus::Left.new()).wait if resolved
        when '/ban' #  removes user from chat. argument = hours to ban.
            until_date = (splitted[1]) ? Time.now.getutc.to_i + splitted[1].to_i * 3600 : 0
            @client.set_chat_member_status(chat_id, resolved.id, TD::Types::ChatMemberStatus::Banned.new(banned_until_date: until_date)).wait if resolved
        when '/block' # add user to blacklist 
            @client.block_user(chat_id) 
        when '/unblock' # add user to blacklist 
            @client.unblock_user(chat_id) 
        when '/leave', '/delete' #  delete / leave chat
            @client.close_chat(chat_id).wait
            @client.leave_chat(chat_id).wait
            @client.delete_chat_history(chat_id, true).wait
            @xmpp.presence(chat_id, :unsubscribed) 
            @xmpp.presence(chat_id, :unavailable)
            @cache[:chats].delete(chat_id)
        when '/sed' # sed-like edit
            sed = splitted[1].split('/')
            @client.search_chat_messages(chat_id, 0, 1, sender_user_id: @me.id, filter: TD::Types::SearchMessagesFilter::Empty.new).then {|msgs| 
                original = msgs.messages[0].content.text.text.to_s
                edited = (sed[0] != '' ) ? original.gsub(Regexp.new(sed[0]), sed[1]) : sed[1]
                @client.edit_message_text(chat_id, msgs.messages[0].id, TD::Types::InputMessageContent::Text.new(:text => { :text => edited, :entities => []}, :disable_web_page_preview => false, :clear_draft => true )) if edited != original
            }.wait
        when '/d' # delete last message
            @client.search_chat_messages(chat_id, 0, 1, sender_user_id: @me.id, filter: TD::Types::SearchMessagesFilter::Empty.new).then {|msgs|   
                @client.delete_messages(chat_id, [msgs.messages[0].id], true)
            }.wait
        when '/dump'
            response = @cache[:chats][chat_id].to_json
        else
            response = 'Unknown command. 
            
            /s/mitsake/mistake/ — Edit last message
            /d — Delete last message
            
            /add @username or id — Creates conversation with specified user
            /join chat_link or id — Joins chat by its link or id
            /invite @username — Invites @username to current chat 
            /kick @username — Removes @username from current chat 
            /ban @username [hours] — Bans @username in current chat for [hours] hrs or forever if [hours] not specified
            /block — Blacklists current user
            /unblock — Removes current user from blacklist
            /leave — Leave current chat
            /delete — Delete current chat
            ' 
        end
        
        @xmpp.incoming_message(chat_id, response) if response
    end
    
    # processing outgoing message from queue #
    def process_outgoing_msg(chat_id, text)
        @logger.debug 'Sending message to user/chat <%s> within Telegram network..' % chat_id.to_s

        # processing /commands #
        return self.process_command(chat_id, text) if text[0] == '/'
        
        # handling replies #
        if text[0] == '>' then 
            splitted = text.split("\n")
            reply_to = splitted[0].scan(/\d/).join('') || 0
            text = splitted.drop(1).join("\n") if reply_to != 0 
        else
            reply_to = 0
        end
        
        # handling files received from xmpp #
        if text.start_with? @@content_upload_prefix  then
            message = TD::Types::InputMessageContent::Document.new(document: TD::Types::InputFile::Remote.new(id: text), caption: { :text => '', :entities => []})
        else
            message = TD::Types::InputMessageContent::Text.new(:text => { :text => text, :entities => []}, :disable_web_page_preview => false, :clear_draft => true )
        end
        
        # send message and mark chat as read #
        @client.send_message(chat_id, message, reply_to_message_id: reply_to)
        @client.view_messages(chat_id, [@cache[:unread_msg].delete(chat_id)], force_read: true) if @cache[:unread_msg][chat_id]
    end

    # update users information and save it to cache #
    def process_chat_info(chat_id, no_subscription = false)
        @logger.debug 'Updating chat id %s..' % chat_id.to_s

        # fullfil cache.. pasha durov, privet. #
        @client.get_chat(chat_id).then { |chat|  
            @cache[:chats][chat_id] = chat   # cache chat 
            @client.download_file(chat.photo.small.id) if chat.photo # download userpic
            @xmpp.presence(chat_id.to_s, :subscribe, nil, nil, @cache[:chats][chat_id].title.to_s) if not no_subscription # send subscription request
            @xmpp.presence(chat_id.to_s, nil, :chat, @cache[:chats][chat_id].title.to_s) if chat.type.instance_of? TD::Types::ChatType::BasicGroup or chat.type.instance_of? TD::Types::ChatType::Supergroup  # send :chat status if its group/supergroup
            self.process_user_info(chat.type.user_id) if chat.type.instance_of? TD::Types::ChatType::Private # process user if its a private chat 
        }.wait
    end
    
    # update user info in cache and sync status to roster if needed #
    def process_user_info(user_id)
        @logger.debug 'Updating user id %s..' % user_id.to_s
        @client.get_user(user_id).then { |user| 
            @cache[:users][user_id] = user  # add to cache 
            self.process_status_update(user_id, user.status) # status update
        }.wait
        @client.get_user_full_info(user_id).then{ |user_info|
            @cache[:users_fi][user_id] = user_info # here is user "bio"
        }.wait
    end

    # convert telegram status to XMPP one
    def process_status_update(user_id, status)
        @logger.debug "Processing status update for user id %s.." % user_id.to_s 
        xmpp_show, xmpp_status = nil, ''
        case status 
        when TD::Types::UserStatus::Online 
            xmpp_show = nil
            xmpp_status = "Online"
        when TD::Types::UserStatus::Offline 
            xmpp_show = (Time.now.getutc.to_i - status.was_online.to_i < 3600) ? :away : :xa
            xmpp_status = DateTime.strptime((status.was_online+Time.now.getlocal(@xmpp.timezone).utc_offset).to_s,'%s').strftime("Last seen at %H:%M %d/%m/%Y")
        when TD::Types::UserStatus::Recently 
            xmpp_show = :dnd
            xmpp_status = "Last seen recently"
        when TD::Types::UserStatus::LastWeek 
            xmpp_show = :unavailable
            xmpp_status = "Last seen last week"
        when TD::Types::UserStatus::LastMonth 
            xmpp_show = :unavailable
            xmpp_status = "Last seen last month"
        end
        @xmpp.presence(user_id.to_s, nil, xmpp_show, xmpp_status) 
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
            bio = @cache[:users_fi][chat_id].bio if @cache[:users_fi].key? chat_id # <DESC>
        end

        # userpic #
        if @cache[:chats][chat_id].photo then # we have userpic 
            userpic = self.format_content_link(@cache[:chats][chat_id].photo.small.remote.id, 'image.jpg', true)
            userpic = Base64.encode64(IO.binread(userpic)) if File.exist? userpic
        end
        
        # ..
        return title, username, firstname, lastname, phone, bio, userpic 
    end
    
    # roster status sync #
    def sync_status()
        @logger.debug "Syncing statuses.."
        @cache[:users].each_value do |user| process_status_update(user.id, user.status) end
    end
    
    # graceful disconnect
    def disconnect(logout)
        @logger.info 'Disconnect request received..'
        @cache[:chats].each_key do |chat_id| @xmpp.presence(chat_id.to_s, :unavailable) end # send offline presences
        (logout) ? @client.log_out : @client.dispose # logout if needed  
        @xmpp.offline!
    end
    
    ###########################################
    ## Format functions #######################
    ###########################################

    # format tg user name #
    def format_username(user_id)
        user_id = @me.id if user_id == 0 # @me
        if not @cache[:users].key? user_id then self.process_user_info(user_id) end # update cache 
        if not @cache[:users].key? user_id then return user_id end # return id if not found anything about this user 
        id = (@cache[:users][user_id].username == '') ? user_id : @cache[:users][user_id].username # username or user id
        name = @cache[:users][user_id].first_name # firstname
        name = name + ' ' + @cache[:users][user_id].last_name if @cache[:users][user_id].last_name != '' # lastname
        return "%s (@%s)" % [name, id]
    end

    # format tg chat name #
    def format_chatname(chat_id)
        if not @cache[:chats].key? chat_id then self.process_chat_info(chat_id, true) end
        if not @cache[:chats].key? chat_id then return chat_id end
        name = '%s (%s)' % [@cache[:chats][chat_id].title, chat_id]
        return name 
    end

    # format reply# 
    def format_reply(chat_id, message_id)
        text = ''
        @client.get_message(chat_id, message_id).then { |message| text = "%s" % message.content.text.text.to_s }.wait 
        text = (text.lines.count > 1) ? "%s..." % text.split("\n")[0] : text
        return "MSG %s (%s..)" % [message_id.to_s, text]
    end
    
    # format content link #
    def format_content_link(file_id, fname, local = false)
        prefix = (local) ? @@content_path : @@content_link
        path = "%s/%s%s" % [prefix, Digest::SHA256.hexdigest(file_id), File.extname(fname)]
        return path
    end
    
end
