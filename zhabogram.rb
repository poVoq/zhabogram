require 'set'
require 'yaml'
require 'yaml/store'
require 'logger' 
require 'xmpp4r'
require 'xmpp4r/discovery'
require 'digest'
require 'base64'
require 'fileutils'
require 'tdlib-ruby'
require_relative 'inc/telegramclient'
require_relative 'inc/xmppcomponent'

Config = YAML.load_file(File.dirname(__FILE__) + '/config.yml')
TelegramClient.configure Config[:telegram] 
Zhabogram =  XMPPComponent.new Config[:xmpp]
Zhabogram.connect()
