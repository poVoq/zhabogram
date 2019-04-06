require 'tdlib-ruby'


class TelegramClient

    # tdlib configuration, shared within all instances #
    def self.configure(params) 
        TD.configure do |config|
            config.lib_path = params[:lib_path] || 'lib/'
            config.client.api_id = params[:api_id] || '17349' # desktop telegram app
            config.client.api_hash = params[:api_hash] || '344583e45741c457fe1862106095a5eb' # desktop telegram app
        end
        TD::Api.set_log_verbosity_level(params[:verbosity] || 1)
    end
    
    # instance initialization #
    def initialize(xmpp, login)
    
        @xmpp = xmpp
        @login = login
        @logger = Logger.new(STDOUT); @logger.progname = '[TelegramClient: %s/%s]' % [@xmpp.user_jid, @login]

        @logger.info 'Spawning Telegram client instance..'        
        @client = TD::Client.new(database_directory: 'sessions/' + @login, files_directory: 'sessions/' + @login + '/files/') # create telegram client instance
        @client.on(TD::Types::Update::AuthorizationState) do |update| self.auth_handler(update) end # register auth update handler 
        @client.on(TD::Types::Update::NewMessage) do |update| self.message_handler(update) end # register new message update handler 
        @client.connect # 
        
        # we will check new messages in queue and auth data in forever loop #
        begin
            loop do 
                self.process_outgoing_msg(@xmpp.message_queue.pop) unless @xmpp.message_queue.empty? # found something in message queue 
                self.process_auth(:code, @xmpp.tg_auth_data[:code]) unless @xmpp.tg_auth_data[:code].nil? # found code in auth queue
                self.process_auth(:password, @xmpp.tg_auth_data[:password]) unless @xmpp.tg_auth_data[:password].nil? # found 2fa password in auth queue
                sleep 0.5
            end
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
        # authorizatio successful #
        when TD::Types::AuthorizationState::Ready 
            @logger.info 'Authorization successful!'
            @xmpp.send_message(nil, 'Authorization successful.')
        end        
    end
    
    # message from telegram network handler # 
    def message_handler(update)
        @logger.info 'Got NewMessage update'
        from = update.message.chat_id 
        text = update.message.content.text.text
        @xmpp.send_message(from, text) if not update.message.is_outgoing
    end
    
    ###########################################
    ## LooP handlers #########################
    ###########################################
    
    # processing authorization #
    def process_auth(typ, data)
        @logger.info 'Check authorization :%s..' % typ.to_s
        @client.check_authentication_code(data) if typ == :code 
        @client.check_authentication_password(data) if typ == :password
        @xmpp.tg_auth = {} # unset it to prevent extracting 2fa password from memory 
    end
    
    # processing outgoing message from queue #
    def process_outgoing_msg(msg)
        @logger.info 'Sending message to user/chat <%s> within Telegram network..' % msg[:to]
        message = TD::Types::InputMessageContent::Text.new(:text => { :text => msg[:text], :entities => []}, :disable_web_page_preview => false, :clear_draft => false )
        @client.send_message(msg[:to].to_i, message)
    end
    
end
