#############################
### Some constants #########
::HELP_MESSAGE = 'Unknown command.
  
  /login <telegram_login> — Connect to Telegram network
  /code 12345 — Enter confirmation code
  /password secret — Enter 2FA password
  /connect ­— Connect to Telegram network if have active session
  /disconnect ­— Disconnect from Telegram network
  /logout — Disconnect from Telegram network and forget session
  
  /sessions — Shows current active sessions (available for admins)
  /debug — Shows some debug information (available for admins)
  /restart — Reset Zhabogram (available for admins)
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
        @config = { host: params["host"] || 'localhost', port: params["port"] || 8899, jid: params["jid"] || 'tlgrm.localhost', secret: params['password'] || '', admins: params['admins'] || [], debug: params['debug'] || false } # default config
        @sessions = {}
        @db =  SQLite3::Database.new(params['db_path'] || 'users.db')
        @db.execute("CREATE TABLE IF NOT EXISTS users(jid varchar(256), login varchar(256), PRIMARY KEY(jid) );")
        @db.results_as_hash = true
    end
    
    # load sessions from db #
    def load_db(jid = nil) # load 
        @logger.info "Initializing database.."
        query = (jid.nil?) ? "SELECT * FROM users" : "SELECT * FROM users where jid = '%s';" % jid
        @logger.debug(query)        
        @db.execute(query) do |session| @sessions[session['jid']] = TelegramClient.new(self, session['jid'], session['login']) end
    end

    # store session to db #
    def update_db(jid, delete = false) # write
        return if not @sessions.key? jid 
        @logger.info "Writing database [%s].." % jid.to_s
        query = (delete) ? "DELETE FROM users where jid = '%s';" % jid.to_s : "INSERT OR REPLACE INTO users(jid, login) VALUES('%s', '%s');" % [jid.to_s, @sessions[jid].login.to_s]
        @logger.debug query
        @db.execute(query)
    end

    # connecting to XMPP server #
    def connect() # :jid => transport_jid, :host => xmpp_server, :port => xmpp_component_port, :secret => xmpp_component_secret
        @logger.info "Connecting.."
        begin
            Jabber::debug = @config[:debug]
            @@transport = Jabber::Component.new( @config[:jid] )
            @@transport.connect( @config[:host], @config[:port] )
            @@transport.auth( @config[:secret] ) 
            @@transport.add_message_callback do |msg| msg.first_element_text('body') ? self.message_handler(msg) : nil  end 
            @@transport.add_presence_callback do |presence| self.presence_handler(presence)  end 
            @@transport.add_iq_callback do |iq| self.iq_handler(iq)  end 
            @@transport.on_exception do |exception, stream, state| self.survive(exception, stream, state) end 
            @logger.info "Connection established"
            self.load_db()
            @logger.info 'Found %s sessions in database.' % @sessions.count
            @sessions.each do |jid, session| self.presence(jid, nil, :subscribe) end
            Thread.stop()
        rescue Interrupt
            @logger.error 'Interrupted!'
            @@transport.on_exception do |exception,| end
            self.disconnect()
            return -11
        rescue Exception => e
            @logger.error 'Connection failed: %s' % e
            @db.close
            exit -8
        end
    end
    
    # transport shutdown #
    def disconnect()
        @logger.info "Closing all connections..."
        @sessions.each do |jid, session| @sessions[jid].disconnect() end
        @@transport.close()
    end
    
    # vse umrut a ya ostanus'... #
    def survive(exception, stream, state)
        @logger.error "Stream error on :%s (%s)" % [state.to_s, exception.to_s]
        @logger.info "Trying to ressurect XMPP stream.."
        self.connect()
    end
    
    # message to users #
    def message(to, from = nil, body = '')
        @logger.info "Sending message from <%s> to <%s>" % [from || @@transport.jid, to]
        msg = Jabber::Message.new
        msg.from = (from) ? "%s@%s" % [from, @@transport.jid.to_s] : @@transport.jid
        msg.to = to
        msg.body = body
        msg.type = :chat
        @logger.debug msg.to_s
        @@transport.send(msg)
    end

    # presence update #
    def presence(to, from = nil, type = nil, show = nil, status = nil, nickname = nil, photo = nil)
        @logger.debug "Presence update request from %s.." % from.to_s
        req = Jabber::Presence.new()
        req.from = from.nil? ? @@transport.jid : "%s@%s" % [from, @@transport.jid] # presence <from> 
        req.to = to # presence <to>
        req.type = type unless type.nil? # pres. type
        req.show = show unless show.nil? # presence <show>
        req.status = status unless status.nil? # presence message 
        req.add_element('nick', {'xmlns' => 'http://jabber.org/protocol/nick'} ).add_text(nickname) unless nickname.nil? # nickname 
        req.add_element('x', {'xmlns' => 'vcard-temp:x:update'} ).add_element("photo").add_text(photo) unless photo.nil? # nickname 
        @logger.debug req.to_s
        @@transport.send(req)
    end

    # request timezone information #
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
    
    #############################
    #### Callback handlers #####
    #############################

    # new message to XMPP component #
    def message_handler(msg)
        return if msg.type == :error
        @logger.info 'Received message from <%s> to <%s>' % [msg.from, msg.to]
        if msg.to == @@transport.jid then self.process_command(msg.from, msg.first_element_text('body') ); return; end # treat message as internal command if received as transport jid
        if @sessions.key? msg.from.bare.to_s then self.request_tz(msg.from) if not @sessions[msg.from.bare.to_s].tz_set?; @sessions[msg.from.bare.to_s].process_outgoing_msg(msg.to.to_s.split('@')[0].to_i, msg.first_element_text('body')); return; end #if @sessions.key? msg.from.bare.to_s and @sessions[msg.from.bare.to_s].online? # queue message for processing session is active for jid from
    end

    # new presence to XMPP component #
    def presence_handler(prsnc) 
        @logger.info "New presence received"
        @logger.debug(prsnc)
        if prsnc.type == :subscribe then reply = prsnc.answer(false); reply.type = :subscribed; @@transport.send(reply); end  # send "subscribed" reply to "subscribe" presence
        if prsnc.to == @@transport.jid and @sessions.key? prsnc.from.bare.to_s and prsnc.type == :unavailable then @sessions[prsnc.from.bare.to_s].disconnect(); return; end # go offline when received offline presence from jabber user 
        if prsnc.to == @@transport.jid and @sessions.key? prsnc.from.bare.to_s then self.request_tz(prsnc.from); @sessions[prsnc.from.bare.to_s].connect(); return; end # connect if we have session 
    end
    
    # new iq (vcard/tz) request to XMPP component #
    def iq_handler(iq)
        @logger.info "New iq received"
        @logger.debug(iq.to_s)
        
        # vcard request #
        if iq.type == :get and iq.vcard and @sessions.key? iq.from.bare.to_s then
            @logger.info "Got VCard request"
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
            @@transport.send(reply)
        # time response #
        elsif iq.type == :result and iq.elements["time"] and @sessions.key? iq.from.bare.to_s then
            @logger.info "Got Timezone response"
            timezone = iq.elements["time"].elements["tzo"].text
            @sessions[iq.from.bare.to_s].timezone = timezone
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
    def process_command(from, body)
        case body.split[0] # /command argument = [command, argument]
        when '/login'  # create new session 
            @sessions[from.bare.to_s] = TelegramClient.new(self, from.bare.to_s, body.split[1]) if not (@sessions.key? from.bare.to_s and @sessions[from.bare.to_s].online?)
            @sessions[from.bare.to_s].connect()
            self.request_tz(from)
            self.update_db(from.bare.to_s)
        when '/code', '/password'  # pass auth data to telegram
            @sessions[from.bare.to_s].process_auth(body.split[0], body.split[1])  if @sessions.key? from.bare.to_s 
        when '/connect'  # go online
            @sessions[from.bare.to_s].connect() if @sessions.key? from.bare.to_s 
        when '/disconnect'  # go offline (without destroying a session) 
            @sessions[from.bare.to_s].disconnect() if @sessions.key? from.bare.to_s
        when '/logout'  # go offline and destroy session
            @sessions[from.bare.to_s].disconnect(true) if @sessions.key? from.bare.to_s
            self.update_db(from.bare.to_s, true)
            @sessions.delete(from.bare.to_s)
        when '/debug' # show some debug information
            return if not @config[:admins].include? from.bare.to_s 
            GC.start
            dump = (defined? Memprof2) ? "/tmp/zhabogram.%s.dump" % Time.now.to_i : nil
            Memprof2.report(out: dump) if dump
            response = "Debug information: \n\n"
            response += "Running from: %s\n" % `ps -p #{$$} -o lstart`.lines.last.strip
            response += "Sessions: %d online | %d total \n" % [ @sessions.inject(0){ |cnt, (jid, sess)| cnt = (sess.online?) ? cnt + 1 : cnt }, @sessions.count]
            response += "System memory used: %d KB\n"  % `ps -o rss -p #{$$}`.lines.last.strip.to_i
            response += "Objects memory allocated: %d bytes \n" % `cut -d' ' -f1 #{dump}`.lines.map(&:to_i).reduce(0, :+) if dump
            response += "\nDetailed memory info saved to %s\n" % dump if dump
            response += "\nRun this transport with --profiler (depends on gem memprof2) to get detailed memory infnormation.\n" if not dump
            self.message(from.bare, nil, response)
        when '/sessions' # show active sessions
            return if not @config[:admins].include? from.bare.to_s 
            response = "Active sessions list: \n\n"
            @sessions.each do |jid, session|  response += "JID: %s | Login: %s | Status: %s (%s) | Telegram profile: %s\n" % [jid, session.login, (session.online == true) ? 'Online' : 'Offline', session.auth_state, (session.me) ? session.format_username(session.me.id) : 'Unknown' ] end
            self.message(from.bare, nil, response)
        when '/restart' # reset transport
            return if not @config[:admins].include? from.bare.to_s 
            self.message(from.bare, nil, 'Trying to restart all active sessions and reconnect to XMPP server..')
            sleep(0.5)
            Process.kill("INT", Process.pid)
        else # unknown command -- display help #
            self.message(from.bare, nil, ::HELP_MESSAGE)
        end

        return
    end    

end 
