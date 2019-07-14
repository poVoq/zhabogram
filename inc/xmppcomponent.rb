#############################
### Some constants #########
::HELP_MESSAGE = 'Unknown command.
  
  /login <telegram_login> — Connect to Telegram network
  /code 12345 — Enter confirmation code
  /password secret — Enter 2FA password
  /connect ­— Connect to Telegram network if have active session
  /disconnect ­— Disconnect from Telegram network
  /reconnect ­— Reconnect to Telegram network
  /logout — Disconnect from Telegram network and forget session
  
  /info — Show information and usage statistics of this instance (only for JIDs specified as administrators)
  /restart — Restart this instance (only for JIDs specified as administrators)
'

#############################

#############################
## XMPP Transport Class #####
#############################

include Jabber::Discovery
include Jabber::Dataforms

class XMPPComponent

    # init class and set logger #
    def initialize(params)
        @@loglevel = params['loglevel'] || Logger::DEBUG
        @logger = Logger.new(STDOUT); @logger.level = @@loglevel; @logger.progname = '[XMPPComponent]'
        @config = { host: params["host"] || 'localhost', port: params["port"] || 8899, jid: params["jid"] || 'tlgrm.localhost', secret: params['password'] || '', admins: params['admins'] || [], debug: params['debug'] } # default config
        @sessions = {}
        @presence_que = {}
        @db =  params['db_path'] || 'users.dat'
        self.load_db()
    end
    
    # load sessions from db #
    def load_db()
        @logger.info "Loading sessions..."
        File.open( @db, 'r' ) {|f| YAML.load(f).each do |jid,login| @sessions[jid] = TelegramClient.new(self, jid, login) end }
    end

    # store session to db #
    def save_db()
        @logger.info "Saving sessions..."
        sessions_store = []
        @sessions.each do |jid,session| store << {jid: jid, login: session.login} end
        File.open( @db, 'w' ) {|f| f.write(YAML.dump(sessions_store)) }
    end

    # connecting to XMPP server #
    def connect() # :jid => transport_jid, :host => xmpp_server, :port => xmpp_component_port, :secret => xmpp_component_secret
        begin
            Jabber::debug = @config[:debug]
            
            # component
            @component = Jabber::Component.new( @config[:jid] )
            @component.connect( @config[:host], @config[:port] )
            @component.auth( @config[:secret] ) 
            @component.add_message_callback do |msg| msg.first_element_text('body') ? self.message_handler(msg) : nil  end 
            @component.add_presence_callback do |presence| self.presence_handler(presence)  end 
            @component.add_iq_callback do |iq| self.iq_handler(iq)  end 
            @component.on_exception do |exception, stream, state| self.survive(exception, stream, state) end 
            @logger.info "Connection to XMPP server established!"

            # disco
            @disco = Jabber::Discovery::Responder.new(@component)
            @disco.identities = [ Identity.new('gateway', 'Telegram Gateway', 'telegram') ]
            @disco.add_features(['http://jabber.org/protocol/disco','jabber:iq:register'])            

            # janbber::iq::register 
            @iq_register = Jabber::Register::Responder.new(@component)
            @iq_register.instructions = 'Please enter your Telegram login'
            @iq_register.add_field(:login, true) do |jid, login| self.process_command(jid, '/login %s' % login) end
            
            # jabber::iq::gateway
            @iq_gateway = Jabber::Gateway::Responder.new(@component) do |iq, query| (@sessions.key? iq.from.bare.to_s and @sessions[iq.from.bare.to_s].online?) ? @sessions[iq.from.bare.to_s].resolve_username(query).to_s + '@' + @component.jid.to_s : ''  end
            @iq_gateway.description = "Specify @username / ID / https://t.me/link"
            @iq_gateway.prompt = "Telegram contact"
            
            @logger.info 'Loaded %s sessions from database.' % @sessions.count
            @sessions.each do |jid, session| self.presence(jid, nil, :subscribe) end
            Thread.new { while @component.is_connected? do @presence_que.each_value { |p| @component.send(p) }; @presence_que.clear; sleep(60); end }  # presence updater thread
            Thread.stop() 
        rescue Interrupt, SignalException
            @logger.error 'Interrupted!'
            @component.on_exception do |exception,| end
            self.disconnect()
            return -11
        rescue Exception => e
            @logger.error 'Connection failed: %s' % e
            self.save_db()
            exit -8
        end
    end
    
    # transport shutdown #
    def disconnect()
        @logger.info "Closing connections..."
        @sessions.each do |jid, session| @sessions[jid].disconnect(); self.presence(jid, nil, :unavailable) end
        @component.close()
    end
    
    # vse umrut a ya ostanus'... #
    def survive(exception, stream, state)
        @logger.error "Stream error on :%s (%s)" % [state.to_s, exception.to_s]
        @logger.info "Trying to revive stream.."
        self.connect()
    end
    
    # message to users #
    def message(to, from = nil, body = '')
        @logger.info "Sending message from <%s> to <%s>" % [from || @component.jid, to]
        msg = Jabber::Message.new
        msg.from = (from) ? "%s@%s" % [from, @component.jid.to_s] : @component.jid
        msg.to = to
        msg.body = body
        msg.type = :chat
        @logger.debug msg.to_s
        @component.send(msg)
    end

    # presence update #
    def presence(to, from = nil, type = nil, show = nil, status = nil, nickname = nil, photo = nil, immediately = true)
        @logger.debug "Presence update request from %s (immed = %s).." % [from.to_s, immediately]
        req = Jabber::Presence.new()
        req.from = from.nil? ? @component.jid : "%s@%s" % [from, @component.jid] # presence <from> 
        req.to = to # presence <to>
        req.type = type unless type.nil? # pres. type
        req.show = show unless show.nil? # presence <show>
        req.status = status unless status.nil? # presence message 
        req.add_element('nick', {'xmlns' => 'http://jabber.org/protocol/nick'} ).add_text(nickname) unless nickname.nil? # nickname 
        req.add_element('x', {'xmlns' => 'vcard-temp:x:update'} ).add_element("photo").add_text(photo) unless photo.nil? # nickname 
        @logger.debug req.to_s
        (immediately) ? @component.send(req) : @presence_que.store(req.from.to_s+req.to.to_s, req)
        # @component.send(req)
    end

    # request timezone information #
    #def request_tz(jid)
        #@logger.debug "Request timezone from JID %s" % jid.to_s
        #iq = Jabber::Iq.new
        #iq.type = :get
        #iq.to = jid
        #iq.from = @component.jid
        #iq.id = 'time_req_1'
        #iq.add_element("time", {"xmlns" => "urn:xmpp:time"})
        #@logger.debug iq.to_s
        #@component.send(iq)
    #end

    #############################
    #### Callback handlers #####
    #############################

    # new message to XMPP component #
    def message_handler(msg)
        return if msg.type == :error
        @logger.info 'Received message from <%s> to <%s>' % [msg.from.to_s, msg.to.to_s]
        @logger.debug msg.to_s
        if msg.to == @component.jid then self.process_command(msg.from, msg.first_element_text('body') ); return; end # treat message as internal command if received as transport jid
        if @sessions.key? msg.from.bare.to_s then 
            # self.request_tz(msg.from) if not @sessions[msg.from.bare.to_s].tz_set?
            return @sessions[msg.from.bare.to_s].process_outgoing_msg(msg.to.to_s.split('@')[0].to_i, msg.first_element_text('body'))
        end 
    end

    # new presence to XMPP component #
    def presence_handler(prsnc) 
        @logger.debug "Received presence :%s from <%s> to <%s>" % [prsnc.type.to_s, prsnc.from.to_s, prsnc.to.to_s]
        @logger.debug(prsnc.to_s)
        if prsnc.type == :subscribe then reply = prsnc.answer(false); reply.type = :subscribed; @component.send(reply); end  # send "subscribed" reply to "subscribe" presence
        if prsnc.to == @component.jid and @sessions.key? prsnc.from.bare.to_s and prsnc.type == :unavailable then @sessions[prsnc.from.bare.to_s].disconnect(); self.presence(prsnc.from, nil, :subscribe) ; return; end # go offline when received offline presence from jabber user 
        if prsnc.to == @component.jid and @sessions.key? prsnc.from.bare.to_s then 
            # self.request_tz(prsnc.from); 
            @sessions[prsnc.from.bare.to_s].connect() || @sessions[prsnc.from.bare.to_s].sync_status()
            return
        end
    end
    
    # new iq (vcard/tz) request to XMPP component #
    def iq_handler(iq)
        @logger.debug "Received iq :%s from <%s> to <%s>" % [iq.type.to_s, iq.from.to_s, iq.to.to_s]
        @logger.debug(iq.to_s)
        
        # vcard request #
        if iq.type == :get and iq.vcard and @sessions.key? iq.from.bare.to_s then
            @logger.debug "VCard request for <%s>" % iq.to.to_s
            fn, nickname, given, family, phone, desc, photo = @sessions[iq.from.bare.to_s].get_contact_info(iq.to.to_s.split('@')[0].to_i)
            vcard = Jabber::Vcard::IqVcard.new()
            vcard["FN"] = fn
            vcard["NICKNAME"] = nickname if nickname
            vcard["URL"] = "https://t.me/%s" % nickname if nickname 
            vcard["N/GIVEN"] = given if given
            vcard["N/FAMILY"] = family if family
            vcard["DESC"] = desc if desc
            vcard["PHOTO/TYPE"] = 'image/jpeg' if photo
            vcard["PHOTO/BINVAL"] = photo if photo
            if phone then  ph = vcard.add_element("TEL"); ph.add_element("HOME"); ph.add_element("VOICE"); ph.add_element("NUMBER"); ph.elements["NUMBER"].text = phone; end
            reply = iq.answer
            reply.type = :result
            reply.elements["vCard"] = vcard
            @logger.debug reply.to_s
            @component.send(reply)
        # time response #
        elsif iq.type == :result and iq.elements["time"] and @sessions.key? iq.from.bare.to_s then
            @logger.debug "Timezone response from <%s>" % iq.from.to_s
            timezone = iq.elements["time"].elements["tzo"].text
            @sessions[iq.from.bare.to_s].timezone = timezone
        elsif iq.type == :get then
            @logger.debug "Unknown iq type <%s>" % iq.from.to_s
            reply = iq.answer
            reply.type = :error
        end
        @component.send(reply)
    end
    
    #############################
    #### Command handlers #####
    #############################

    # process internal /command #
    def process_command(from, body)
        case body.split[0] # /command argument = [command, argument]
        when '/login'  # create new session 
            @sessions[from.bare.to_s] = TelegramClient.new(self, from.bare.to_s, body.split[1]) if not (@sessions.key? from.bare.to_s and @sessions[from.bare.to_s].online?)
            @sessions[from.bare.to_s].connect()
            # self.request_tz(from)
            self.save_db()
        when '/code', '/password'  # pass auth data to telegram
            @sessions[from.bare.to_s].process_auth(body.split[0], body.split[1])  if @sessions.key? from.bare.to_s 
        when '/connect'  # go online
            @sessions[from.bare.to_s].connect() if @sessions.key? from.bare.to_s 
        when '/disconnect'  # go offline (without destroying a session) 
            @sessions[from.bare.to_s].disconnect() if @sessions.key? from.bare.to_s
        when '/reconnect'  # reconnect
            @sessions[from.bare.to_s].disconnect() if @sessions.key? from.bare.to_s
            sleep(0.1)
            @sessions[from.bare.to_s].connect() if @sessions.key? from.bare.to_s 
        when '/logout'  # go offline and destroy session
            @sessions[from.bare.to_s].disconnect(true) if @sessions.key? from.bare.to_s
            self.save_db()
            @sessions.delete(from.bare.to_s)
        when '/info' # show some debug information
            return if not @config[:admins].include? from.bare.to_s 
            response = "Information about this instance: \n\n"
            response += "Running from: %s\n" % `ps -p #{$$} -o lstart`.lines.last.strip
            response += "System memory used: %d KB\n"  % `ps -o rss -p #{$$}`.lines.last.strip.to_i
            response += "\n\nSessions: %d online | %d total \n" % [ @sessions.inject(0){ |cnt, (jid, sess)| cnt = (sess.online?) ? cnt + 1 : cnt }, @sessions.count]
            @sessions.each do |jid, session|  response += "JID: %s | Login: %s | Status: %s (%s) | %s\n" % [jid, session.login, (session.online == true) ? 'Online' : 'Offline', session.auth_state, (session.me) ? session.format_contact(session.me.id) : 'Unknown' ] end
            self.message(from.bare, nil, response)
        when '/restart' # reset transport
            return if not @config[:admins].include? from.bare.to_s 
            self.message(from.bare, nil, 'Trying to restart all active sessions and reconnect to XMPP server..')
            sleep(1)
            Process.kill("INT", Process.pid)
        else # unknown command -- display help #
            self.message(from.bare, nil, ::HELP_MESSAGE)
        end

        return true
    end    

end 
