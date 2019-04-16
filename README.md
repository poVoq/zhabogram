### Dependencies ###

* Ruby >= 1.9
* ruby-sqlite3 >= 1.3
* xmpp4r == 0.5.6
* tdlib-ruby == 2.0 with pre-compiled _libtdjson.so_

There is pre-compiled _libtdjson.so_ for Debian Stretch x64 in repository.  
For any other distro you need to manually compile [**tdlib**](https://github.com/tdlib/td) and place _libtdjson.so_ to relative **lib/** directory (or **LD_LIBRARY_PATH**).

### Installation ###

First of all, you need to create component listener on your Jabber server. 
For example, for ejabberd in **/etc/ejabberd/ejabberd.yml**:

```
listen:  
  -  
    port: 8888  
    module: ejabberd_service  
    access: all  
    shaper_rule: fast  
    ip: "127.0.0.1"  
    service_check_from: false  
    hosts:  
        "tlgrm.localhost":  
            password: "secret"
```


Next, rename **config.yml.example** to **config.yml** and edit **xmpp** section to match your component listener:


```
xmpp:
	db_path: 'users.db'  
	jid: 'tlgrm.localhost'  
	host: 'localhost'  
	port: 8888  
	secret: 'secret'  
	loglevel: 0   
```

### Configuration ###

It is good idea to obtain Telegram API ID from [**https://my.telegram.org**](https://my.telegram.org) to remove demo key requests limit, and then edit in **config.yml**:

```
telegram:
    api_id: '845316' # telegram API ID (my.telegram.org) #
    api_hash: '27fe5224bc822bf3a45e015b4f9dfdb7' # telegram API HASH (my.telegram.org) #
    ...
```

### How to receive files from Telegram ###

First of all, you need to set up web server that will serve some directory in your filesystem.
Example nginx config: 

```
server {
	listen 80;
	server_name tlgrm.localhost;
	location /content {
		alias /var/zhabogram;
	}
}
```

You need to set `content_path` and `content_link` in **config.yml**.  
  
Set `content_path` according to location (for our example it will be `/var/zhabogram/content`).  
Set `content_link` according to server_name (for our example it will be `http://tlgrm.localhost`)  


### How to send files to Telegram chats ###

You need to setup `mod_http_upload` for your XMPP server.  
For example, for ejabberd in **/etc/ejabberd/ejabberd.yml**

```
modules:
  mod_http_upload:
    docroot: "/var/ejabberd/upload" # this must be a valid path, user ownership and SELinux flags must be set accordingly
    put_url: "https://xmpp.localhost:5443/upload/@HOST@"
    get_url: "https://xmppfiles.localhost/upload/@HOST@"
    access: local
    max_size: 500000000 #500 MByte
    thumbnail: false
    file_mode: "0644"
    dir_mode: "0744"
```

Then you need to setup nginx proxy that will serve `get_url` path, because Telegram do not allowing URLs with non-default ports.  
Example nginx config:  

```
server {
	listen 80;
	listen 443 ssl;

	server_name xmppfiles.localhost;

        # SSL settigns #
        keepalive_timeout   60;
        ssl_certificate      /etc/ssl/domain.crt;
        ssl_certificate_key  /etc/ssl/domain.key;
        ssl_protocols SSLv3 TLSv1 TLSv1.1 TLSv1.2;
        ssl_ciphers  "RC4:HIGH:!aNULL:!MD5:!kEDH";
        add_header Strict-Transport-Security 'max-age=604800';

        location / {
            proxy_pass https://xmpp.localhost:5443;
        }	

}

```
