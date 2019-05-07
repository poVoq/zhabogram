# Some very important libraries'
require 'yaml'
require 'logger' 
require 'xmpp4r'
require 'xmpp4r/discovery'
require 'digest'
require 'base64'
require 'sqlite3'
require 'tdlib-ruby'
require_relative 'inc/telegramclient'
require_relative 'inc/xmppregister'
require_relative 'inc/xmppgateway'
require_relative 'inc/xmppcomponent'

# configuration
Config  = YAML.load_file(File.dirname(__FILE__) + '/config.yml')
TelegramClient.configure(Config['telegram']) # configure tdlib
Zhabogram = XMPPComponent.new(Config['xmpp']) # spawn zhabogram 
Zhabogram.connect()
