require 'xmpp4r'
require 'sqlite3'

#############################
### Some constants #########
::HELP_MESSAGE = "Unknown command. \n\n Please, use /login <phonenumber> to try log in. ☺"
#############################

#############################
## XMPP Transport Class #####
#############################
class XMPPComponent

    # init class and set logger #
    def initialize(params)
        @logger = Logger.new(STDOUT); @logger.level = params['loglevel'] || Logger::DEBUG; @logger.progname = '[XMPPComponent]'
        @config = { host: params["host"] || 'localhost', port: params["port"] || 8899, jid: params["jid"] || 'tlgrm.rxtx.us', secret: params['secret'] || '' } # default config
        @sessions = {}
        @db =  SQLite3::Database.new(params['db_path'] || 'users.db')
        @db.execute("CREATE TABLE IF NOT EXISTS users(jid varchar(256), tg_login varchar(256), PRIMARY KEY(jid) );")
        @db.results_as_hash = true
    end
    
    # database #
    def load_db(jid = nil) # load 
        @logger.info "Initializing database..."
        query = (jid.nil?) ? "SELECT * FROM users" : "SELECT * FROM users where jid = '%s';" % jid
        @logger.debug(query)
        @db.execute(query) do |user| 
            @logger.info "Found session for JID %s and TG login %s" % [ user["jid"].to_s, user["tg_login"] ]
            @sessions[user["jid"]] = XMPPSession.new(user["jid"], user["tg_login"])
        end
    end
    def update_db(jid, delete = false) # write
        return if not @sessions.key? jid 
        @logger.info "Writing database [add %s].." % jid.to_s
        query = (delete) ? "DELETE FROM users where jid = '%s';" % jid.to_s : "INSERT OR REPLACE INTO users(jid, tg_login) VALUES('%s', '%s');" % [jid.to_s, @sessions[jid].tg_login.to_s]
        @logger.debug query
        @db.execute(query)
    end


    # transport initialization & connecting to XMPP server #
    def connect() # :jid => transport_jid, :host => xmpp_server, :port => xmpp_component_port, :secret => xmpp_component_secret
        @logger.info "Connecting.."
        begin
            @@transport = Jabber::Component.new( @config[:jid] )
            @@transport.connect( @config[:host], @config[:port] )
            @@transport.auth( @config[:secret] ) 
            @@transport.add_message_callback do |msg| msg.first_element_text('body') ? self.message_handler(msg) : nil  end 
            @@transport.add_presence_callback do |presence| self.presence_handler(presence)  end 
            @@transport.add_iq_callback do |iq| self.iq_handler(iq)  end 
            @logger.info "Connection established"
            self.load_db()
            @logger.info 'Found %s sessions in database.' % @sessions.count
            @sessions.each do |jid, session| 
                @logger.info "Sending presence to %s" % jid
                p = Jabber::Presence.new()
                p.to = jid
                p.from = @@transport.jid 
                p.type = :subscribe
                @logger.debug p
                @@transport.send(p)
            end
            Thread.stop()
        rescue Exception => e
            @logger.info 'Connection failed: %s' % e
            @db.close
            exit 1
        end
    end
    
    #############################
    #### Callback handlers #####
    #############################

    # new message to XMPP component #
    def message_handler(msg)
        @logger.info 'New message from [%s] to [%s]' % [msg.from, msg.to]
        return self.process_internal_command(msg.from.bare.to_s, msg.first_element_text('body') ) if msg.to == @@transport.jid # treat message as internal command if received as transport jid
        return @sessions[msg.from.bare.to_s].queue_message(msg.to.to_s, msg.first_element_text('body')) if @sessions.key? msg.from.bare.to_s and @sessions[msg.from.bare.to_s].online? # queue message for processing session is active for jid from
    end
    
    def presence_handler(presence) 
        @logger.info "New presence iq received"
        @logger.debug(presence)
        if presence.type == :subscribe then reply = presence.answer(false); reply.type = :subscribed; @@transport.send(reply); end  # send "subscribed" reply to "subscribe" presence
        if presence.to == @@transport.jid and @sessions.key? presence.from.bare.to_s and presence.type == :unavailable then @sessions[presence.from.bare.to_s].offline!; return; end # go offline when received offline presence from jabber user 
        if presence.to == @@transport.jid and @sessions.key? presence.from.bare.to_s then @sessions[presence.from.bare.to_s].connect(); return; end # connect if we have session 
    end

    def iq_handler(iq)
        @logger.info "New iq received"
        @logger.debug(iq)
    end
    
    #############################
    #### Command handlers #####
    #############################

    # process internal /command #
    def process_internal_command(jfrom, body)
        case body.split[0] # /command argument = [command, argument]
        when '/login'  # creating new session if not exists and connect if user already has session
            puts @sessions
            @sessions[jfrom] = XMPPSession.new(jfrom, body.split[1]) if not @sessions.key? jfrom
            @sessions[jfrom].connect() 
            self.update_db(jfrom)
        when '/code', '/password'  # pass auth data if we have session 
            typ = body.split[0][1..8]
            data = body.split[1]
            @sessions[jfrom].enter_auth_data(typ, data)  if @sessions.key? jfrom 
        when '/disconnect'  # going offline without destroying a session 
            @sessions[jfrom].offline! if @sessions.key? jfrom
        when '/logout'  # destroying session
            @sessions[jfrom].offline! if @sessions.key? jfrom
            self.update_db(jfrom, true)
            @sessions.delete(jfrom)
        else # unknown command -- display help #
            msg = Jabber::Message.new
            msg.from = @@transport.jid
            msg.to = jfrom
            msg.body = ::HELP_MESSAGE
            msg.type = :chat
            @@transport.send(msg) 
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
        @logger = Logger.new(STDOUT); @logger.progname = '[XMPPSession: %s/%s]' % [jid, tg_login] # init logger 
        @logger.info "Initializing new XMPPSession..."
        @user_jid, @tg_login, @tg_auth_data, @message_queue = jid, tg_login, {code: nil, password: nil}, Queue.new() # init class variables 
    end
    
    # connect to tg #
    def connect()
        return if self.online?
        @logger.info "Starting Telegram session"
        @online = nil
        self.subscription_req(nil) 
        @telegram_thr = Thread.new{ TelegramClient.new(self, @tg_login) } # init tg instance in new thread
    end
    
    ###########################################

    # send message to current user via XMPP  #
    def send_message(from = nil, body = '')
        @logger.info "Incoming message from Telegram network <- %s" % from.to_s
        reply = Jabber::Message.new
        reply.type = :chat
        reply.from = from.nil? ? @@transport.jid : from.to_s+'@'+@@transport.jid.to_s
        reply.to = @user_jid 
        reply.body = body
        @logger.debug reply
        @@transport.send(reply)
    end    
    
    # subscription request to current user via XMPP #
    def subscription_req(from, nickname = nil)
        @logger.info "Subscription request from %s.." %from.to_s
        req = Jabber::Presence.new()
        req.from = from.nil? ? @@transport.jid : from.to_s+'@'+@@transport.jid.to_s # presence <from> 
        req.to = @user_jid # presence <to>
        req.type = :subscribe
        req.add_element('nick', {'xmlns' => 'http://jabber.org/protocol/nick'} ).add_text(nickname) unless nickname.nil?
        @logger.debug req
        @@transport.send(req)
    end
    
    # presence update #
    def presence_update(from, status, message, type = nil)
        @logger.info "Presence update request from %s.." %from.to_s
        req = Jabber::Presence.new()
        req.from = from.nil? ? @@transport.jid : from.to_s+'@'+@@transport.jid.to_s # presence <from> 
        req.to = @user_jid # presence <to>
        req.show = status unless status.nil? # presence <show>
        req.type = type unless type.nil? # pres. type
        req.status = message # presence message 
        @logger.debug req
        @@transport.send(req)
    end
        
    ###########################################
        
    # queue message (we will share this queue within :message_queue to Telegram client thread) #
    def queue_message(to, text = '')
        @logger.info "Queuing message to be sent to Telegram network user -> " % to
        @message_queue << {to: to.split('@')[0], text: text}
    end

    # enter auth data (we will share this data within :tg_auth_data to Telegram client thread ) #
    def enter_auth_data(typ, data) 
        @logger.info "Authorizing in Telegram network with :%s" % typ
        @tg_auth_data[typ.to_sym] = data
    end 
    
    ###########################################

    # session status #
    def online?() @online end
    def online!() @online = true; @tg_auth = {}; self.presence_update(nil, nil, "Logged in as " + @tg_login.to_s) end
    def offline!() @online = false; self.presence_update(nil, nil, "Logged out", :unavailable); end
end
