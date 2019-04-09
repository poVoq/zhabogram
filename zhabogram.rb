# Some very important libraries'
require 'yaml'
require 'logger' 
require 'xmpp4r'
require 'digest'
require 'fileutils'
require 'sqlite3'
require 'tdlib-ruby'
require_relative 'inc/telegramclient'
require_relative 'inc/xmppcomponent'

# Configuration file #
Config  = YAML.load_file(File.dirname(__FILE__) + '/config.yml')

# Configure Telegram Client #
TelegramClient.configure(Config['telegram'])
XMPPComponent.new(Config['xmpp']).connect()
