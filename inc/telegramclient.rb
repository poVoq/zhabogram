require 'tdlib-ruby'
require 'digest' 

class TelegramClient

    # tdlib configuration, shared within all instances #
    def self.configure(params) 
        @@loglevel = params['loglevel'] || Logger::DEBUG
        @@content_path = params['content_path'] || '/tmp'
        @@content_link = params['content_link'] || 'https://localhost/tg_media'
        @@content_size_limit = params["content_size_limit"] || 100 * 1024 * 1024 
        TD.configure do |config|
            config.lib_path = params['path'] || 'lib/' # we hope it's here
            config.client.api_id = params['api_id'] || '17349' # desktop telegram app
            config.client.api_hash = params['api_hash'] || '344583e45741c457fe1862106095a5eb' # desktop telegram app
            config.client.device_model = params['useragent'] || 'Zhabogram XMPP Gateway'
            config.client.application_version = params['version'] || '-1.0' # hmm...
            config.client.use_test_dc = params['use_test_dc'] || false
            config.client.system_version = '42' # I think I have permission to hardcode The Ultimate Question of Life, the Universe, and Everything?..
        end
        TD::Api.set_log_verbosity_level(params['verbosity'] || 1)
    end
    
    # instance initialization #
    def initialize(xmpp, login)
        return if not @@loglevel # call .configure() first
    
        @logger = Logger.new(STDOUT); @logger.level = @@loglevel; @logger.progname = '[TelegramClient: %s/%s]' % [xmpp.user_jid, login] # create logger
        @xmpp = xmpp # our XMPP user session. we will send messages back to Jabber through this instance. 
        @login = login # store tg login 
        @cache = {chats: {}, users: {}, unread_msg: {} } # we will store our cache here
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
        @client.on(TD::Types::Update::UserStatus) do |update| self.status_update_handler(update) end # register status handler 
        @client.connect # 
        
        # we will check for outgoing messages in a queue and/or auth data from XMPP thread while XMPP indicates that service is online #
        begin
            while not @xmpp.online? === false do 
                self.process_outgoing_msg(@xmpp.message_queue.pop) unless @xmpp.message_queue.empty? # found something in message queue 
                self.process_auth(:code, @xmpp.tg_auth_data[:code]) unless @xmpp.tg_auth_data[:code].nil? # found code in auth queue
                self.process_auth(:password, @xmpp.tg_auth_data[:password]) unless @xmpp.tg_auth_data[:password].nil? # found 2fa password in auth queue
                sleep 0.1
            end
        rescue Exception => e
            @logger.error 'Unexcepted exception! %s' % e.to_s
        ensure
            @logger.info 'Exitting gracefully...'
            @client.dispose
        end
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
            @xmpp.send_message(nil, 'Please, enter authorization code via /code 12345')
        # auth stage 2: wait for 2fa passphrase #
        when TD::Types::AuthorizationState::WaitPassword
            @logger.info 'Waiting for 2FA password..'
            @xmpp.send_message(nil, 'Please, enter 2FA passphrase via /password 12345')
        # authorization successful -- indicate that client is online and retrieve contact list  #
        when TD::Types::AuthorizationState::Ready 
            @logger.info 'Authorization successful!'
            @xmpp.online!
            @client.get_chats(limit=9999).then { |chats| chats.chat_ids.each do |chat_id| self.process_chat_info(chat_id) end }.wait 
            @logger.info "Contact list updating finished"
            self.sync_roster()
        when TD::Types::AuthorizationState::Closed
            @logger.info 'Session closed.'
            @xmpp.offline!
        end        
    end
    
    # message from telegram network handler # 
    def message_handler(update)
        @logger.debug 'Got NewMessage update'
        @logger.debug update.message.to_json

        return if update.message.is_outgoing # ignore outgoing 
        return if not @cache[:chats].key? update.message.chat_id
        
        # media? #
        content = nil
        @logger.debug update.message.content.to_json
        case update.message.content #  content = [content, name, mime]
            when TD::Types::MessageContent::Photo  then content = [update.message.content.photo.sizes[-1].photo, update.message.content.photo.id.to_s + '.jpg', 'image/jpeg']
            when TD::Types::MessageContent::Sticker  then content = [update.message.content.sticker.sticker, update.message.content.sticker.emoji.to_s + '.webp', 'image/webp']
            when TD::Types::MessageContent::Audio then content = [update.message.content.audio.audio, update.message.content.audio.file_name.to_s, update.message.content.audio.mime_type.to_s] 
            when TD::Types::MessageContent::Document then content = [update.message.content.document.document, update.message.content.document.file_name.to_s, update.message.content.document.mime_type.to_s]
        end 
        @client.download_file(content[0].id) if content  # download it if already not
                
        # formatting...
        text = (content.nil?) ? update.message.content.text.text.to_s : update.message.content.caption.text.to_s
        text = "[%s (%s), %d bytes] | %s | %s" % [content[1], content[2], content[0].size.to_i, self.format_content_link(content[0].remote.id, content[1]), text] if content   # content format 
        text = "[FWD From %s] %s" % [self.format_username(update.message.forward_info.sender_user_id), text] if update.message.forward_info.instance_of? TD::Types::MessageForwardInfo::MessageForwardedFromUser  # fwd 
        text = "[Reply to MSG %s] %s" % [update.message.reply_to_message_id.to_s, text]  if update.message.reply_to_message_id.to_i != 0 # reply
        text = "[MSG %s] [%s] %s" % [update.message.id.to_s, self.format_username(update.message.sender_user_id), text] # username/id
        
        # send and add message id to unreads
        @cache[:unread_msg][update.message.chat_id] = update.message.id
        @xmpp.send_message(update.message.chat_id.to_s, text)
    end
    
    # new chat update -- when tg client discovers new chat #
    def new_chat_handler(update)   
        @logger.debug 'Got NewChat update'
        @logger.debug update.to_json
        self.process_chat_info(update.chat.id)
    end

    # edited msg #
    def message_edited_handler(update)
        @logger.debug 'Got MessageEdited update'
        @logger.debug update.to_json
        
        # formatting
        text = "[MSG %s EDIT] %s" % [update.message_id.to_s, update.new_content.text.text.to_s]
        @xmpp.send_message(update.chat_id.to_s, text)        
    end

    # deleted msg #
    def message_deleted_handler(update)
        @logger.debug 'Got MessageDeleted update'
        @logger.debug update.to_json
        return if not update.is_permanent
        text = "[MSG ID %s DELETE]" % update.message_ids.join(',')
        @xmpp.send_message(update.chat_id.to_s, text)                
    end

    # file msg -- symlink to download path #
    def file_handler(update)
        @logger.debug 'Got File update'
        @logger.debug update.to_json
        if update.file.local.is_downloading_completed then
            fname = update.file.local.path.to_s
            target = "%s/%s%s" % [@@content_path, Digest::SHA256.hexdigest("Current user = %s, File ID = %s" % [@tg_login.to_s, update.file.remote.id]), File.extname(fname)]
            @logger.debug 'Downloading of <%s> completed! Link to <%s>' % [fname, target] 
            File.symlink(fname, target)
        end
    end
    
    # status update handler #
    def status_update_handler(update)
        @logger.debug 'Got new StatusUpdate'
        @logger.debug update.to_json
        presence, message = self.format_status(update.status)
        @xmpp.presence_update(update.user_id.to_s, presence, message)
    end

    
    ###########################################
    ## LooP handlers #########################
    ###########################################
    
    # processing authorization #
    def process_auth(typ, data)
        @logger.debug 'check_authorization :%s..' % typ.to_s
        @client.check_authentication_code(data) if typ == :code 
        @client.check_authentication_password(data) if typ == :password
        @xmpp.tg_auth_data = {}
    end
    
    # processing outgoing message from queue #
    def process_outgoing_msg(msg)
        @logger.debug 'Sending message to user/chat <%s> within Telegram network..' % msg[:to]
        chat_id, text, reply_to = msg[:to].to_i, msg[:text], 0
        
        # handling replies #
        if msg[:text][0] == '>' then 
            splitted = msg[:text].split("\n")
            reply_to, reply_text = splitted[0].scan(/\d/)[0] || 0
            text = splitted.drop(1).join("\n") if reply_to != 0 
        end
        
        # handle commands... (todo) #
        #
        
        # mark all messages within this chat as read #
        @client.view_messages(chat_id, [@cache[:unread_msg][chat_id]], force_read: true) if @cache[:unread_msg][chat_id]
        @cache[:unread_msg][chat_id] = nil
        
        # send message #
        message = TD::Types::InputMessageContent::Text.new(:text => { :text => text, :entities => []}, :disable_web_page_preview => true, :clear_draft => false )
        @client.send_message(chat_id, message, reply_to_message_id: reply_to)
    end

    # update users information and save it to cache #
    def process_chat_info(chat_id)
        @logger.debug 'Updating chat id %s..' % chat_id.to_s

        # fullfil cache.. pasha durov, privet. #
        @client.get_chat(chat_id).then { |chat|  
            @cache[:chats][chat_id] = chat   # cache chat 
            self.process_user_info(chat.type.user_id) if chat.type.instance_of? TD::Types::ChatType::Private # cache user if it is private chat
        }.wait

        # send to roster #
        if @cache[:chats].key? chat_id 
            @logger.debug "Sending presence to roster.."
            @xmpp.subscription_req(chat_id.to_s, @cache[:chats][chat_id].title.to_s) # send subscription request
            case @cache[:chats][chat_id].type # determine status / presence
                when TD::Types::ChatType::BasicGroup, TD::Types::ChatType::Supergroup then presence, status = :chat, @cache[:chats][chat_id].title.to_s
                when TD::Types::ChatType::Private then presence, status = self.format_status(@cache[:users][chat_id].status)
            end
            @xmpp.presence_update(chat_id.to_s, presence, status) # send presence
        end
    end
    
    # update user info #
    def process_user_info(user_id)
        @logger.debug 'Updating user id %s..' % user_id.to_s
        @client.get_user(user_id).then { |user| @cache[:users][user_id] = user }.wait
    end
    
    ###########################################
    ## Format functions #######################
    ###########################################
    
    # convert telegram status to XMPP one
    def format_status(status)
        presence, message = nil, ''
        case status 
        when TD::Types::UserStatus::Online 
            presence = nil
            message = "Online"
        when TD::Types::UserStatus::Offline 
            presence = (Time.now.getutc.to_i - status.was_online.to_i < 3600) ? :away : :xa
            message = DateTime.strptime(status.was_online.to_s,'%s').strftime("Last seen at %H:%M %d/%m/%Y")
        when TD::Types::UserStatus::Recently 
            presence = :dnd
            message = "Last seen recently"
        when TD::Types::UserStatus::LastWeek 
            presence = :unavailable
            message = "Last seen last week"
        when TD::Types::UserStatus::LastMonth 
            presence = :unavailable
            message = "Last seen last month"
        end
        return presence, message
    end
    
    # format tg user name #
    def format_username(user_id)
        if not @cache[:users].key? user_id then self.process_user_info(user_id) end
        id = (@cache[:users][user_id].username == '') ? user_id : @cache[:users][user_id].username
        name = '%s %s (@%s)' % [@cache[:users][user_id].first_name, @cache[:users][user_id].last_name, id]
        name.sub! ' ]', ']'
        return name 
    end
    
    # format content link #
    def format_content_link(file_id, fname)
        path = "%s/%s%s" % [@@content_link, Digest::SHA256.hexdigest("Current user = %s, File ID = %s" % [@tg_login.to_s, file_id.to_s]).to_s, File.extname(fname)]
        return path
    end
end
