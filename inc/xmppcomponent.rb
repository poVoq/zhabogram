require 'sqlite3'
require 'xmpp4r'
require 'digest' 

#############################
### Some constants #########
::HELP_MESSAGE = 'Unknown command.
  
  /login <telegram_login> — Connect to Telegram network
  /code 12345 — Enter confirmation code
  /password secret — Enter 2FA password
  /connect ­— Connect to Telegram network if have active session
  /disconnect ­— Disconnect from Telegram network
  /logout — Disconnect from Telegram network and forget session
'

#############################

#############################
## XMPP Transport Class #####
#############################
class XMPPComponent

    # init class and set logger #
    def initialize(params)
        @@loglevel = params['loglevel'] || Logger::DEBUG
        @logger = Logger.new(STDOUT); @logger.level = @@loglevel; @logger.progname = '[XMPPComponent]'
        @config = { host: params["host"] || 'localhost', port: params["port"] || 8899, jid: params["jid"] || 'tlgrm.rxtx.us', secret: params['secret'] || '' } # default config
        @sessions = {}
        @db =  SQLite3::Database.new(params['db_path'] || 'users.db')
        @db.execute("CREATE TABLE IF NOT EXISTS users(jid varchar(256), tg_login varchar(256), PRIMARY KEY(jid) );")
        @db.results_as_hash = true
    end
    
    # database #
    def load_db(jid = nil) # load 
        @logger.info "Initializing database.."
        query = (jid.nil?) ? "SELECT * FROM users" : "SELECT * FROM users where jid = '%s';" % jid
        @logger.debug(query)
        @db.execute(query) do |user| 
            @logger.info "Found session for JID %s and Telegram login %s" % [ user["jid"].to_s, user["tg_login"] ]
            @sessions[user["jid"]] = XMPPSession.new(user["jid"], user["tg_login"])
        end
    end
    def update_db(jid, delete = false) # write
        return if not @sessions.key? jid 
        @logger.info "Writing database [%s].." % jid.to_s
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
                @logger.debug "Sending presence to %s" % jid
                p = Jabber::Presence.new()
                p.to = jid
                p.from = @@transport.jid 
                p.type = :subscribe
                @logger.debug p
                @@transport.send(p)
            end
            Thread.stop()
        rescue Exception => e
            @logger.error 'Connection failed: %s' % e
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
        return self.process_internal_command(msg.from, msg.first_element_text('body') ) if msg.to == @@transport.jid # treat message as internal command if received as transport jid
        return @sessions[msg.from.bare.to_s].tg_outgoing(msg.from, msg.to.to_s, msg.first_element_text('body')) #if @sessions.key? msg.from.bare.to_s and @sessions[msg.from.bare.to_s].online? # queue message for processing session is active for jid from
    end
    
    def presence_handler(presence) 
        @logger.debug "New presence iq received"
        @logger.debug(presence)
        if presence.type == :subscribe then reply = presence.answer(false); reply.type = :subscribed; @@transport.send(reply); end  # send "subscribed" reply to "subscribe" presence
        if presence.to == @@transport.jid and @sessions.key? presence.from.bare.to_s and presence.type == :unavailable then @sessions[presence.from.bare.to_s].disconnect(); return; end # go offline when received offline presence from jabber user 
        if presence.to == @@transport.jid and @sessions.key? presence.from.bare.to_s then @sessions[presence.from.bare.to_s].request_tz(presence.from); @sessions[presence.from.bare.to_s].connect(); return; end # connect if we have session 
    end

    def iq_handler(iq)
        @logger.debug "New iq received"
        @logger.debug(iq.to_s)
        
        # vcard request #
        if iq.type == :get and iq.vcard and @sessions.key? iq.from.bare.to_s then
            @logger.debug "Got VCard request"
            vcard = @sessions[iq.from.bare.to_s].make_vcard(iq.to.to_s)
            reply = iq.answer
            reply.type = :result
            reply.elements["vCard"] = vcard
            @@transport.send(reply)
        # time response #
        elsif iq.type == :result and iq.elements["time"] and @sessions.key? iq.from.bare.to_s then
            @logger.debug "Got Timezone response"
            timezone = iq.elements["time"].elements["tzo"].text
            @sessions[iq.from.bare.to_s].set_tz(timezone)
        elsif iq.type == :get then
            reply = iq.answer
            reply.type = :error
        end
        @@transport.send(reply)
    end
    
    #############################
    #### Command handlers #####
    #############################

    # process internal /command #
    def process_internal_command(from, body)
        case body.split[0] # /command argument = [command, argument]
        when '/login'  # creating new session if not exists and connect if user already has session
            @sessions[from.bare.to_s] = XMPPSession.new(from.bare.to_s, body.split[1]) if not @sessions.key? from.bare.to_s
            @sessions[from.bare.to_s].request_tz(from) 
            @sessions[from.bare.to_s].connect() 
            self.update_db(from.bare.to_s)
        when '/code', '/password'  # pass auth data if we have session 
            @sessions[from.bare.to_s].tg_auth(body.split[0], body.split[1])  if @sessions.key? from.bare.to_s 
        when '/connect'  # going online 
            @sessions[from.bare.to_s].connect() if @sessions.key? from.bare.to_s
        when '/disconnect'  # going offline without destroying a session 
            @sessions[from.bare.to_s].disconnect() if @sessions.key? from.bare.to_s
        when '/logout'  # destroying session
            @sessions[from.bare.to_s].disconnect(true) if @sessions.key? from.bare.to_s
            self.update_db(from.bare.to_s, true)
            @sessions.delete(from.bare.to_s)
        else # unknown command -- display help #
            msg = Jabber::Message.new
            msg.from = @@transport.jid
            msg.to = from.bare.to_s
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
    attr_reader :user_jid, :tg_login, :timezone
    attr_accessor :online
    
    # start XMPP user session and Telegram client instance #
    def initialize(jid, tg_login)
        @logger = Logger.new(STDOUT); @logger.level = @@loglevel; @logger.progname = '[XMPPSession: %s/%s]' % [jid, tg_login] # init logger 
        @logger.info "Initializing new session.."
        @user_jid, @tg_login = jid, tg_login 
        @timezone = '-00:00'
    end
    
    # connect to tg #
    def connect()
        return if self.online?
        @logger.info "Spawning Telegram client.."
        @online = nil
        @telegram = TelegramClient.new(self, @tg_login) # init tg instance in new thread
    end
    
    # disconnect from tg#
    def disconnect(logout = false)
        return if not self.online? or not @telegram
        @logger.info "Disconnecting Telegram client.."
        @telegram.disconnect(logout)
    end
        
    ###########################################

    # send message to current user via XMPP  #
    def incoming_message(from = nil, body = '')
        @logger.info "Received new message from Telegram peer %s" % from || "[self]"
        reply = Jabber::Message.new
        reply.type = :chat
        reply.from = from.nil? ? @@transport.jid : from.to_s+'@'+@@transport.jid.to_s
        reply.to = @user_jid 
        reply.body = body
        @logger.debug reply
        @@transport.send(reply)
    end    
    
    # presence update #
    def presence(from, type = nil, show = nil, status = nil, nickname = nil)
        @logger.debug "Presence update request from %s.." %from.to_s
        req = Jabber::Presence.new()
        req.from = from.nil? ? @@transport.jid : from.to_s+'@'+@@transport.jid.to_s # presence <from> 
        req.to = @user_jid # presence <to>
        req.type = type unless type.nil? # pres. type
        req.show = show unless show.nil? # presence <show>
        req.status = status unless status.nil? # presence message 
        req.add_element('nick', {'xmlns' => 'http://jabber.org/protocol/nick'} ).add_text(nickname) unless nickname.nil? # nickname 
        @logger.debug req
        @@transport.send(req)
    end
    
    ###########################################
        
    # queue message (we will share this queue within :message_queue to Telegram client thread) #
    def tg_outgoing(from, to, text = '')
        @logger.debug "Sending message to be sent to Telegram network user -> " % to
        self.request_tz(from) if not self.tz_set?
        @telegram.process_outgoing_msg(to.split('@')[0].to_i, text)
    end

    # enter auth data (we will share this data within :auth_data {} to Telegram client thread ) #
    def tg_auth(typ, data) 
        @logger.info "Authenticating in Telegram network with :%s" % typ
        @telegram.process_auth(typ, data) 
    end 

    # make vcard from telegram contact #
    def make_vcard(to)
        @logger.debug "Requesting information to make a VCard for Telegram contact..." # title, username, firstname, lastname, phone, bio, userpic 
        fn, nickname, given, family, phone, desc, photo = @telegram.get_contact_info(to.split('@')[0].to_i)
        vcard = Jabber::Vcard::IqVcard.new()
        vcard["FN"] = fn
        vcard["NICKNAME"] = nickname if nickname
        vcard["URL"] = "https://t.me/%s" % nickname if nickname 
        vcard["N/GIVEN"] = given if given
        vcard["N/FAMILY"] = family if family
        vcard["DESC"] = desc if desc
        vcard["PHOTO/TYPE"] = 'image/jpeg' if photo
        vcard["PHOTO/BINVAL"] = photo if photo
        if phone then 
            ph = vcard.add_element("TEL")
            ph.add_element("HOME")
            ph.add_element("VOICE")
            ph.add_element("NUMBER")
            ph.elements["NUMBER"].text = phone
        end
        @logger.debug vcard.to_s
        return vcard
    end
    
    ## timezones ##
    def request_tz(jid)
        @logger.debug "Request timezone from JID %s" % jid.to_s
        iq = Jabber::Iq.new
        iq.type = :get
        iq.to = jid
        iq.from = @@transport.jid
        iq.id = 'time_req_1'
        iq.add_element("time", {"xmlns" => "urn:xmpp:time"})
        @logger.debug iq.to_s
        @@transport.send(iq)
    end
    
    def set_tz(timezone)
        @logger.debug "Set TZ to %s" % timezone
        @timezone = timezone
        @logger.debug "Resyncing contact list.."
        @telegram.sync_status()
    end
    
    ###########################################

    # session status #
    def online?() @online end
    def online!() @logger.info "Connection established"; @online = true; self.presence(nil, :subscribe); self.presence(nil, nil, nil, "Logged in as " + @tg_login.to_s) end
    def offline!() @online = false; self.presence(nil, :unavailable, nil, "Logged out"); @telegram = nil; end
    def tz_set?() return @timezone != '-00:00' end
end
