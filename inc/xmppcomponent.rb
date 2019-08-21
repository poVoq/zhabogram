class XMPPComponent

    ##  initialize zhabogram 
    def initialize(**config)
        @sessions = {} # sessions list
        @queue = {} # presence queue
        @logger   = Logger.new(STDOUT, level: config[:loglevel], progname: 'XMPPComponent')
        @config   = {host: config[:host], port: config[:port], jid: config[:jid], password: config[:password], debug: config[:debug]}
        @db = YAML::Store.new(config[:db])
        @db.transaction do @db[:sessions] ||= {} end 
    end

    ##  connect to XMPP server 
    def connect() 
        begin
            @component = Jabber::Component.new(@config[:jid]) # init XMPP component 
            @component.connect(@config[:host], @config[:port])  # connect to XMPP server
            @component.auth(@config[:password])  # authorize
            @component.on_exception do |error,| @logger.error(error) and self.connect() end  # exception handler  
            @component.add_presence_callback do |stanza| self.handle_subscription(stanza) if stanza.type == :subscribe end   # presence handler 
            @component.add_presence_callback do |stanza| self.handle_presence(stanza)     if stanza.to == @component.jid  end  # presence handler 
            @component.add_message_callback  do |stanza| self.handle_message(stanza)      if stanza.type != :error  and stanza.first_element_text('body') end  # messages handler  
            @component.add_iq_callback       do |stanza| self.handle_vcard_iq(stanza)     if stanza.type == :get    and stanza.vcard                      end  # vcards handler 
            @logger.warn 'Connected to XMPP server' 
            @db.transaction do  @db[:sessions].each do |jid, session| @sessions[jid] = TelegramClient.new(self, jid, session) end end # probe all known sessions
            @sessions.each_key do |jid| self.send_presence(jid,nil,:probe) end
            Thread.new { while @component.is_connected? do sleep 60; @queue.delete_if {|_, presence| @component.send(presence) || true } end }   # status updater thread
            Thread.stop()  # stop main thread loop 
        rescue Exception => error
            @logger.error 'Disconnecting.. %s' % error.to_s
            @sessions.each_value do |session| session.disconnect() end  # close all sessions
            @db.transaction do @sessions.each do |jid, session| @db[:sessions][jid] = session.session end end # save sessions
            @component.on_exception do |exception,| end # disable exception handling 
            @component.close()  # close stream
            exit -1 # bye
        end
    end

    ############################################################
    #### Callback handlers (from XMPP) #########################

    def handle_subscription(presence)
        @logger.warn 'Subscription request from %s to %s' % [presence.from, presence.to]
        @logger.debug presence.to_s
        answer = presence.answer(false)
        answer.type = :subscribed
        @component.send(answer)
    end

    def handle_presence(presence)
        @logger.warn 'Presence (%s) from %s to %s' % [presence.type || 'online', presence.from, presence.to]
        @logger.debug presence.to_s
        @sessions[presence.from.bare.to_s] = TelegramClient.new(self, presence.from.bare.to_s) unless @sessions.key? presence.from.bare.to_s  # create session
        @sessions[presence.from.bare.to_s] = nil if presence.type == :unsubscribed # destroy session
        @sessions[presence.from.bare.to_s].disconnect() if presence.type == :unavailable or presence.type == :error # go offline
        @sessions[presence.from.bare.to_s].connect() if not presence.type # go online
    end

    def handle_message(message)
        @logger.warn 'Message from %s to %s' % [message.from, message.to]
        @logger.debug message.to_s
        @sessions[message.from.bare.to_s].process_outgoing_message(message.to.to_s.split('@').first.to_i, message.first_element_text('body')) if @sessions.key? message.from.bare.to_s
    end
    
    def handle_vcard_iq(iq)
        @logger.warn 'VCard request from %s for %s' % [iq.from, iq.to]
        chat, user = @sessions[iq.from.bare.to_s].get_contact(iq.to.to_s.split('@').first.to_i) if @sessions.key? iq.from.bare.to_s
        vcard = Jabber::Vcard::IqVcard.new()
        vcard["FN"] = chat.title  if chat
        vcard["NICKNAME"], vcard["N/GIVEN"], vcard["N/FAMILY"], vcard["TEL/NUMBER"] = user.username, user.first_name, user.last_name, user.phone_number if user 
        vcard["PHOTO/TYPE"], vcard["PHOTO/BINVAL"] = 'image/jpeg', Base64.encode64(IO.binread(chat.photo.small.local.path)) if chat and chat.photo and File.exist? chat.photo.small.local.path
        answer = iq.answer
        answer.type = :result
        answer.elements['vCard'] = vcard
        @logger.debug answer.to_s
        @component.send(answer)
    end

    ############################################################
    #### XMPP gateway functions (to XMPP)  #####################
    
    def send_message(to, from=nil, body='')
        @logger.warn "Got message from %s to %s" % [from||@component.jid, to] 
        message = Jabber::Message.new
        message.from = (from) ? "%s@%s" % [from.to_s, @component.jid.to_s] : @component.jid
        message.to = to
        message.body = body
        message.type = :chat
        @logger.debug message.to_s
        @component.send(message)
    end

    def send_presence(to, from=nil, type=nil, show=nil, status=nil, nickname=nil, photo=nil, immed=true)
        @logger.info "Got presence :%s from %s to %s" % [type, from||@component.jid, to]
        presence = Jabber::Presence.new()
        presence.from = from.nil? ? @component.jid : "%s@%s" % [from.to_s, @component.jid.to_s] # presence <from> 
        presence.to = to # presence <to>
        presence.type = type unless type.nil? # pres. type
        presence.show = show unless show.nil? # presence <show>
        presence.status = status unless status.nil? # presence message 
        presence.add_element('nick', {'xmlns' => 'http://jabber.org/protocol/nick'} ).add_text(nickname) unless nickname.nil? # nickname 
        presence.add_element('x', {'xmlns' => 'vcard-temp:x:update'} ).add_element("photo").add_text(photo) unless photo.nil? # nickname 
        @logger.debug presence.to_s
        (immed) ? @component.send(presence) : @queue.store(presence.from.to_s+presence.to.to_s, presence)
    end

end 
