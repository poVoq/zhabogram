### Dependencies ###

* Ruby >= 1.9
* ruby-sqlite3 >= 1.3
* xmpp4r == 0.5.6
* tdlib-ruby == 2.0 with pre-compiled _libtdjson.so_

(there is pre-compiled _libtdjson.so_ for Debian Stretch x64 in repository)

### Installation ###

First of all, you need to create component listener on your Jabber server. 
For example, for ejabberd:

```
port: 8888  
module: ejabberd_service  
access: all  
shaper_rule: fast  
ip: "127.0.0.1"  
service_check_from: false  
hosts:  
	"telegram.jabber.ru":  
		password: "secret"
```


Next, move **config.yml.example** to and **config.yml** and edit **xmpp** section to match component listener:


```
db_path: 'users.db'  
jid: 'telegram.jabber.ru'  
host: 'localhost'  
port: 8888  
secret: 'secret'  
loglevel: 0   
```

If neccessary, edit **telegram** section too. 
