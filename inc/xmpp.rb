require 'xmpp4r'

#############################
## XMPP Transport Class #####
#############################
class XMPPComponent
    attr_accessor :jid

    # transport initialization & connecting to XMPP server #
    def connect(params) # :jid => transport_jid, :host => xmpp_server, :port => xmpp_component_port, :secret => xmpp_component_secret
        Logging.log.info '[XMPP] Connecting...'
        begin
            @@transport = Jabber::Component.new( params[:jid] )
            @@transport.connect( params[:host], params[:port] )
            @@transport.auth( params[:secret] ) 
            @@transport.add_message_callback do |msg| msg.first_element_text('body') ? self.message_handler(msg) : nil  end 
            @sessions = {}
            Logging.log.info '[XMPP] Connection established'
            Thread.stop()
        rescue Exception => e
            Logging.log.info '[XMPP] Connection failed (%s)' % e
            exit 1
        end
    end
        
    # new message to XMPP component #
    def message_handler(msg)
        Logging.log.debug '[XMPP] New message from [%s] to [%s]' % [msg.from, msg.to]

        return self.process_internal_command(msg.from.bare, msg.first_element_text('body') ) if msg.to == @@transport.jid # treat message as internal command if received as transport jid
        return @sessions[msg.from.bare].queue_message(msg.to, msg.first_element_text('body')) if @sessions.key? msg.from.bare # queue message for processing session is active for jid from
    end
    
    # process internal /command #
    def process_internal_command(jfrom, body)
        case body.split[0] # /command argument = [command, argument]
        when '/help' # 
        when '/login' # Create new session
            @sessions[jfrom] = XMPPSession.new(jfrom, body.split[1])
        when '/code', '/password'  # Enter auth code / 2fa password
            @sessions[jfrom].enter_auth_data(body.split[0], body.split[1]) 
        else # Unknown command
            reply = Jabber::Message.new; reply.from, reply.to, reply.body, reply.type = @@transport.jid, jfrom, 'Unknown command', :chat 
            @@transport.send(reply) 
        end
    end
end 

#############################   
## XMPP Session Class #######
#############################

class XMPPSession < XMPPComponent
    attr_accessor :user_jid, :tg_login, :tg_auth_data, :message_queue
    
    # start XMPP user session and Telegram client instance #
    def initialize(jid, tg_login)
        Logging.log.info "[XMPPSession] [%s] Starting Telegram session as [%s]" % [jid, tg_login]
        @user_jid, @tg_login, @tg_auth_data, @message_queue = jid, tg_login, {code: nil, password: nil}, Queue.new()
        @tg_thread = Thread.new{ TelegramClient.new(self, tg_login) }
    end
    
    # send message to XMPP  #
    def send_message(from = nil, body = '')
        Logging.log.info "[XMPPSession] [%s] Incoming message from Telegram network <- [%s].." % [@user_jid, from.to_s]
        puts 1
        from = from.nil? ? @@transport.jid : from.to_s+'@'+@@transport.jid.to_s
        puts 2
        reply = Jabber::Message.new; reply.from, reply.to, reply.body, reply.type = from, @user_jid, body, :chat 
        puts reply
        @@transport.send(reply)
    end    
    
    # queue message (we will share this queue within :message_queue to Telegram client thread) #
    def queue_message(to, text = '')
        Logging.log.info "[XMPPSession] [%s] Queuying message to Telegram network -> [%s].." % [@user_jid, to]
        @message_queue << {to: to.split('@')[0], text: text}
    end

    # enter auth data (we will share this data within :tg_auth_data to Telegram client thread ) #
    def enter_auth_data(typ, data) 
        Logging.log.info "[XMPPSession] [%s] Authorizing in Telegram with [%s]" % [@user_jid, typ]  
        @tg_auth_data[typ[1..8].to_sym] = data
    end 

end
