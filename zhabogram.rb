# Some very important libraries'
require 'yaml'
require 'logger' 
require 'xmpp4r'
require 'digest'
require 'base64'
require 'sqlite3'
require 'tdlib-ruby'
require 'memprof2' if ARGV.include? '--profiler'
require_relative 'inc/telegramclient'
require_relative 'inc/xmppcomponent'

# profiler #
Memprof2.start if defined? Memprof2

# configuration
Config  = YAML.load_file(File.dirname(__FILE__) + '/config.yml')
TelegramClient.configure(Config['telegram']) # configure tdlib
Zhabogram = XMPPComponent.new(Config['xmpp']) # spawn zhabogram 
loop do Zhabogram.connect(); sleep(1); end # forever loop jk till double ctrl+c
