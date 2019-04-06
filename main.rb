require_relative 'inc/logger'
require_relative 'inc/telegram'
require_relative 'inc/xmpp'

Logging.log.info '[MAIN] Starting Zhabogram v0.o1...'
TelegramClient.configure(verbose: 2)
XMPPComponent.new().connect(host: 'localhost', port: '8899', jid: 'tlgrm2.rxtx.us', secret: '')
