# Some very important libraries'
require 'yaml'
require 'logger' 
require_relative 'inc/telegramclient'
require_relative 'inc/xmppcomponent'

# Configuration file #
Config  = YAML.load_file(File.dirname(__FILE__) + '/config.yml')

# Configure Telegram Client #
TelegramClient.configure(api_id: Config['telegram']['api_id'], api_hash: Config['telegram']['api_hash'], verbosity: Config['telegram']['verbosity'])
XMPPComponent.new().connect(host: Config['xmpp']['host'], port: Config['xmpp']['port'], jid: Config['xmpp']['jid'], secret: Config['xmpp']['secret'])
