require 'tdlib-ruby'

class TelegramClient

    # tdlib configuration, shared within all instances #
    def self.configure(params) 
        TD.configure do |config|
            config.lib_path = params[:lib_path] || 'lib/'
            config.client.api_id = params[:api_id] || 430850
            config.client.api_hash = params[:api_hash] || '3d3cfcbd30d0805f757c5fc521004861'
        end
        TD::Api.set_log_verbosity_level(params[:verbose] || 1)
    end
    
    # instance initialization #
    def initialize(xmpp, login)
    
        @xmpp = xmpp
        @login = login

        Logging.log.info '[TelegramClient] [%s] Initializing..' % @login
        
        @client = TD::Client.new(database_directory: 'sessions/' + @login, files_directory: 'sessions/' + @login + '/files/') # create telegram client instance
        @client.on(TD::Types::Update::AuthorizationState) do |update| self.auth_handler(update) end # register auth update handler 
        @client.on(TD::Types::Update::NewMessage) do |update| self.message_handler(update) end # register new message update handler 
        @client.connect # 
        
        # we will check new messages in queue and auth data in forever loop #
        #begin
            loop do 
                self.process_outgoing_msg(@xmpp.message_queue.pop) unless @xmpp.message_queue.empty? # found something in message queue 
                self.process_auth(:code, @xmpp.tg_auth_data[:code]) unless @xmpp.tg_auth_data[:code].nil? # found code in auth queue
                self.process_auth(:password, @xmpp.tg_auth_data[:password]) unless @xmpp.tg_auth_data[:password].nil? # found 2fa password in auth queue
                sleep 0.5
            end
        #ensure
            #Logging.log.info '[TelegramClient] Exitting gracefully...'
            #@client.dispose
        #end
    end

    # authorization handler #
    def auth_handler(update)
        Logging.log.debug '[TelegramClient] [%s] Authorization state changed: %s' % [@login, update.authorization_state]
        case update.authorization_state

        # auth stage 0: specify login #
        when TD::Types::AuthorizationState::WaitPhoneNumber
            Logging.log.debug '[TelegramClient] [%s] Logging in..' % @login
            @client.set_authentication_phone_number(@login)
         # auth stage 1: wait for authorization code #    
        when TD::Types::AuthorizationState::WaitCode
            @xmpp.send_message(nil, 'Please, enter authorization code via /code 12345')
            Logging.log.debug '[TelegramClient] [%s] Waiting for Authorization code..' % @login
        # auth stage 2: wait for 2fa passphrase #
        when TD::Types::AuthorizationState::WaitPassword
            @xmpp.send_message(nil, 'Please, enter 2FA passphrase via /password 12345')
            Logging.log.debug '[TelegramClient] [%s] Waiting for 2FA password..' % @login
        # authorizatio successful #
        when TD::Types::AuthorizationState::Ready 
            @xmpp.send_message(nil, 'Authorization successful.')
            Logging.log.debug '[TelegramClient] [%s] Authorization successful.' % @login
        end        
    end
    
    # message from telegram network handler # 
    def message_handler(update)
        Logging.log.debug '[TelegramClient] [%s] Got NewMessage update <%s>' % [@login, update.message]
        from = update.message.chat_id 
        text = update.message.content.text.text
        @xmpp.send_message(from, text) if not update.message.is_outgoing
    end
    
    ##################################################
    
    # processing authorization #
    def process_auth(typ, data)
        Logging.log.debug '[TelegramClient] [%s] Authorizing with <%s> in Telegram...'  % [@login, typ.to_s]
        @client.check_authentication_code(data) if typ == :code 
        @client.check_authentication_password(data) if typ == :password
        @xmpp.tg_auth = {} # unset it to prevent extracting 2fa password from memory 
    end
    
    # processing outgoing message from queue #
    def process_outgoing_msg(msg)
        Logging.log.debug '[TelegramClient] [%s] Sending message to user/chat <%s> within Telegram network..' % [@login, msg[:to]]
        message = TD::Types::InputMessageContent::Text.new(:text => { :text => msg[:text], :entities => []}, :disable_web_page_preview => false, :clear_draft => false )
        @client.send_message(msg[:to].to_i, message)
    end
end
