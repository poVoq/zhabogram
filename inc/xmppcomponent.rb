require 'xmpp4r'

#############################
### Some constants #########
::HELP_MESSAGE = "Unknown command. \n\n Please, use /login <phonenumber> to try log in. ☺"
#############################

#############################
## XMPP Transport Class #####
#############################
class XMPPComponent
    # init class and set logger #
    def initialize()
        @logger = Logger.new(STDOUT); @logger.progname = '[XMPPComponent]'
    end

    # transport initialization & connecting to XMPP server #
    def connect(params) # :jid => transport_jid, :host => xmpp_server, :port => xmpp_component_port, :secret => xmpp_component_secret
        @logger.info "Connecting.."
        begin
            @@transport = Jabber::Component.new( params[:jid] )
            @@transport.connect( params[:host], params[:port] )
            @@transport.auth( params[:secret] ) 
            @@transport.add_message_callback do |msg| msg.first_element_text('body') ? self.message_handler(msg) : nil  end 
            @sessions = {}
            @logger.info "Connection established"
            Thread.stop()
        rescue Exception => e
            @logger.info 'Connection failed: %s' % e
            exit 1
        end
    end
    
    #############################
    #### Callback handlers #####
    #############################

    # new message to XMPP component #
    def message_handler(msg)
        @logger.info 'New message from [%s] to [%s]' % [msg.from, msg.to]
        return self.process_internal_command(msg.from.bare, msg.first_element_text('body') ) if msg.to == @@transport.jid # treat message as internal command if received as transport jid
        return @sessions[msg.from.bare].queue_message(msg.to.to_s, msg.first_element_text('body')) if @sessions.key? msg.from.bare and @sessions[msg.from.bare].online? # queue message for processing session is active for jid from
    end
    
    #############################
    #### Command handlers #####
    #############################

    # process internal /command #
    def process_internal_command(jfrom, body)
        case body.split[0] # /command argument = [command, argument]
            when '/login'  then @sessions[jfrom] = XMPPSession.new(jfrom, body.split[1]) # create new session for jid <jfrom> and spawn tg instance
            when '/code', '/password'  then @sessions[jfrom].enter_auth_data(body.split[0][1..8], body.split[1])  if @sessions.key? jfrom # pass auth data to telegram instance 
            when '/logout' then @sessions[jfrom].offline! if @sessions.key? jfrom # go offline 
            else  reply = Jabber::Message.new; reply.from, reply.to, reply.body, reply.type = @@transport.jid, jfrom, ::HELP_MESSAGE, :chat; @@transport.send(reply) # unknown command -- we will display sort of help message.
        end
    end

end 

#############################   
## XMPP Session Class #######
#############################
class XMPPSession < XMPPComponent
    attr_reader :user_jid, :tg_login, :tg_auth_data, :message_queue
    attr_accessor :online
    
    # start XMPP user session and Telegram client instance #
    def initialize(jid, tg_login)
        @logger = Logger.new(STDOUT); @logger.progname = '[XMPPSession: %s/%s]' % [jid, tg_login]
        @logger.info "Starting Telegram session"
        @user_jid, @tg_login, @tg_auth_data, @message_queue = jid, tg_login, {code: nil, password: nil}, Queue.new()
        @tg_client_thread = Thread.new{ TelegramClient.new(self, tg_login) }
    end
    
    ###########################################

    # send message to current user via XMPP  #
    def send_message(from = nil, body = '')
        @logger.info "Incoming message from Telegram network <- %s" % from.to_s
        from = from.nil? ? @@transport.jid : from.to_s+'@'+@@transport.jid.to_s
        reply = Jabber::Message.new; reply.from, reply.to, reply.body, reply.type = from, @user_jid, body, :chat 
        @@transport.send(reply)
    end    
    
    # queue message (we will share this queue within :message_queue to Telegram client thread) #
    def queue_message(to, text = '')
        @logger.info "Queuing message to be sent to Telegram network user -> " % to
        @message_queue << {to: to.split('@')[0], text: text}
    end

    # enter auth data (we will share this data within :tg_auth_data to Telegram client thread ) #
    def enter_auth_data(typ, data) 
        logger.info "Authorizing in Telegram network with :%s" % typ
        @tg_auth_data[typ.to_sym] = data
    end 
    
    ###########################################

    # session status #
    def online?() @online end
    def online!() @online = true end
    def offline!() @online = false end
end
