all:

regen_certs:
	touch server.key
	make server.crt

cacert.pem: server.key
	openssl req -new -x509 -days 3650 -key server.key -out cacert.pem -subj "/C=JP/ST=Shimane/L=Matz-e city/O=Ruby Core Team/CN=Ruby Test CA/emailAddress=security@ruby-lang.org"

server.crt: cacert.pem
	openssl req -new -key server.key -out server.csr -subj "/C=JP/ST=Shimane/O=Ruby Core Team/OU=Ruby Test/CN=Server 1" -addext "subjectAltName = DNS:localhost"
	openssl x509 -days 3650 -CA cacert.pem -CAkey server.key -set_serial 00 -in server.csr -req -copy_extensions copy -out server.crt
	rm server.csr

server_ip_san.crt: cacert.pem
	openssl req -new -key server.key -out server.csr -subj "/C=JP/ST=Shimane/O=Ruby Core Team/OU=Ruby Test/CN=Server 2" -addext "subjectAltName = IP:127.0.0.1,IP:::1"
	openssl x509 -days 3650 -CA cacert.pem -CAkey server.key -set_serial 01 -in server.csr -req -copy_extensions copy -out server_ip_san.crt
	rm server.csr
