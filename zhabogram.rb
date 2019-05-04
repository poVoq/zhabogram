# Some very important libraries'
require 'yaml'
require 'logger' 
require 'xmpp4r'
require 'digest'
require 'base64'
require 'sqlite3'
require 'tdlib-ruby'
require_relative 'inc/telegramclient'
require_relative 'inc/xmppcomponent'

# configuration
Config  = YAML.load_file(File.dirname(__FILE__) + '/config.yml')
TelegramClient.configure(Config['telegram']) # configure tdlib

# run
Zhabogram = XMPPComponent.new(Config['xmpp'])    
Zhabogram.connect()
