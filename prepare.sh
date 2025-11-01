#!/bin/bash

# =============================================================================
# Автоматическая установка LEMP: OpenSSL + NGINX (QUIC) + PHP 8.4 + MariaDB
# Требуется: Ubuntu/Debian, root или sudo
# =============================================================================

set -e  # Остановка при любой ошибке

echo "Обновление системы и установка зависимостей..."
apt install -y build-essential cmake git wget tar \
    libpcre3 libpcre3-dev zlib1g-dev libssl-dev \
    libgd-dev libgeoip-dev libxslt1-dev libperl-dev \
    libreadline-dev libsqlite3-dev libbz2-dev \
    libcurl4-openssl-dev libjpeg-dev libpng-dev libfreetype6-dev \
    libonig-dev libzip-dev libargon2-dev libsodium-dev \
    libxml2-dev libtidy-dev libicu-dev pkg-config

# =============================================================================
# 1. OpenSSL (с QUIC и TLS 1.3)
# =============================================================================
echo "Установка OpenSSL с поддержкой QUIC..."
cd /tmp

if [ ! -d "openssl" ]; then
  echo "Папка openssl не найдена. Клонируем и собираем OpenSSL..."
  
  git clone https://github.com/openssl/openssl.git
  cd openssl || exit 1
  
  ./Configure \
    --prefix=/usr/local \
    --openssldir=/usr/local/ssl \
    shared zlib \
    enable-quic \
    enable-tls1_2 \
    enable-tls1_3 \
    no-weak-ssl-ciphers \
    -fPIC \
    linux-x86_64
  
  make -j$(nproc)
  
  echo "Сборка OpenSSL завершена."
else
  echo "Папка openssl уже существует. Пропускаем клонирование и сборку."
  cd openssl || exit 1
fi
make -j$(nproc)
make install install_sw install_ssldirs
echo '/usr/local/lib64' | sudo tee /etc/ld.so.conf.d/openssl.conf
ldconfig
ln -sf /usr/local/bin/openssl /usr/bin/openssl
echo "OpenSSL установлен: $(openssl version)"

# =============================================================================
# 2. NGINX (с HTTP/3, Brotli, GeoIP2, NJS)
# =============================================================================
echo "Сборка NGINX с HTTP/3, Brotli, GeoIP2 и NJS..."
if [ ! -d "nginx" ]; then
    git clone https://github.com/nginx/nginx.git
    cd nginx
    git clone https://github.com/google/ngx_brotli.git
    cd ngx_brotli && git submodule update --init && cd ..
    git clone https://github.com/leev/ngx_http_geoip2_module.git
    git clone https://github.com/nginx/njs.git
    
    ./configure \
      --prefix=/etc/nginx \
      --sbin-path=/usr/sbin/nginx \
      --modules-path=/usr/lib/nginx/modules \
      --conf-path=/etc/nginx/nginx.conf \
      --error-log-path=/var/log/nginx/error.log \
      --http-log-path=/var/log/nginx/access.log \
      --pid-path=/var/run/nginx.pid \
      --lock-path=/var/run/nginx.lock \
      --http-client-body-temp-path=/var/cache/nginx/client_temp \
      --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
      --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
      --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
      --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
      --user=nginx \
      --group=nginx \
      --with-threads \
      --with-file-aio \
      --with-http_ssl_module \
      --with-http_v2_module \
      --with-http_v3_module \
      --with-http_realip_module \
      --with-http_addition_module \
      --with-http_sub_module \
      --with-http_gunzip_module \
      --with-http_gzip_static_module \
      --with-http_random_index_module \
      --with-http_secure_link_module \
      --with-http_stub_status_module \
      --with-http_auth_request_module \
      --with-http_xslt_module=dynamic \
      --with-http_image_filter_module=dynamic \
      --with-http_geoip_module=dynamic \
      --with-http_perl_module=dynamic \
      --with-stream \
      --with-stream_ssl_module \
      --with-stream_realip_module \
      --with-stream_geoip_module=dynamic \
      --with-stream_ssl_preread_module \
      --with-pcre-jit \
      --with-debug \
      --add-module=./ngx_brotli \
      --add-module=./ngx_http_geoip2_module \
      --add-module=./njs/nginx
      make -j$(nproc)
    else
        make -j$(nproc)
    fi
make install

# Создание пользователя nginx
useradd -r -s /sbin/nologin nginx || true

# Создание директорий
mkdir -p /var/cache/nginx /var/log/nginx /var/run
chown nginx:nginx /var/cache/nginx /var/log/nginx

# systemd unit для nginx
cat > /etc/systemd/system/nginx.service <<'EOF'
[Unit]
Description=nginx - high performance web server
Documentation=https://nginx.org/en/docs/
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=/usr/sbin/nginx -s quit
PrivateTmp=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable --now nginx
ln -sf /usr/sbin/nginx /usr/bin/nginx
echo "NGINX установлен и запущен"

# =============================================================================
# 3. PHP 8.4 + FPM
# =============================================================================
echo "Сборка PHP 8.4 с FPM..."
cd /tmp
wget https://www.php.net/distributions/php-8.4.14.tar.gz
tar -xvf php-8.4.14.tar.gz
cd php-8.4.14

./configure \
  --prefix=/usr/local/php \
  --enable-fpm \
  --with-fpm-user=nginx \
  --with-fpm-group=nginx \
  --enable-opcache \
  --enable-intl \
  --enable-mbstring \
  --with-mysqli=mysqlnd \
  --with-pdo-mysql=mysqlnd \
  --with-curl \
  --with-openssl \
  --with-zlib \
  --with-bz2 \
  --enable-exif \
  --enable-ftp \
  --with-gd \
  --with-jpeg \
  --with-freetype \
  --enable-bcmath \
  --enable-calendar \
  --with-sodium \
  --with-argon2 \
  --enable-pcntl \
  --enable-sockets \
  --enable-sysvmsg \
  --enable-sysvsem \
  --enable-sysvshm \
  --with-readline \
  --enable-filter \
  --enable-session \
  --enable-tokenizer \
  --enable-xml \
  --enable-simplexml \
  --enable-dom \
  --enable-xmlreader \
  --enable-xmlwriter \
  --with-xsl \
  --enable-soap \
  --enable-zip \
  --with-libzip \
  --disable-rpath \
  --enable-shared

make -j$(nproc)
make install

# Конфиги FPM
cp /usr/local/php/etc/php-fpm.conf.default /usr/local/php/etc/php-fpm.conf 2>/dev/null || true
cp /usr/local/php/etc/php-fpm.d/www.conf.default /usr/local/php/etc/php-fpm.d/www.conf

cat > /usr/local/php/etc/php-fpm.d/www.conf <<'EOF'
[www]
user = nginx
group = nginx
listen = /usr/local/php/var/php-fpm.sock
listen.owner = nginx
listen.group = nginx
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
EOF

mkdir -p /usr/local/php/var
chown nginx:nginx /usr/local/php/var

# systemd unit для php-fpm
cat > /etc/systemd/system/php-fpm.service <<'EOF'
[Unit]
Description=PHP FastCGI Process Manager
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/php/sbin/php-fpm --nodaemonize
ExecReload=/bin/kill -USR2 $MAINPID
Restart=on-failure
User=nginx
Group=nginx

[Install]
WantedBy=multi-user.target
EOF

ln -sf /usr/local/php/bin/php /usr/bin/php
systemctl daemon-reexec
systemctl enable --now php-fpm
echo "PHP-FPM установлен и запущен"

# =============================================================================
# 4. MariaDB (из исходников)
# =============================================================================
echo "Сборка MariaDB..."
cd /tmp
git clone https://github.com/MariaDB/server.git
cd server
mkdir build && cd build

cmake .. \
  -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb \
  -DWITH_SSL=system \
  -DDEFAULT_CHARSET=utf8mb4 \
  -DDEFAULT_COLLATION=utf8mb4_general_ci \
  -DWITH_INNODB_DISALLOW_WRITES=ON \
  -DWITH_READLINE=ON \
  -DWITH_ZLIB=system \
  -DWITH_PCRE=system

make -j$(nproc)
make install

# Создание пользователя mysql
useradd -r -s /sbin/nologin mysql || true

# Конфиг my.cnf
mkdir -p /etc/mysql
cat > /etc/mysql/my.cnf <<'EOF'
[client]
socket = /usr/local/mariadb/data/mysql.sock

[mysqld]
socket = /usr/local/mariadb/data/mysql.sock
datadir = /usr/local/mariadb/data
basedir = /usr/local/mariadb
user = mysql
port = 3306
EOF

# Инициализация БД
mkdir -p /usr/local/mariadb/data
chown mysql:mysql /usr/local/mariadb/data
/usr/local/mariadb/scripts/mariadb-install-db \
  --user=mysql \
  --basedir=/usr/local/mariadb \
  --datadir=/usr/local/mariadb/data \
  --auth-root-authentication-method=normal

# systemd unit для mariadb
cat > /etc/systemd/system/mariadb.service <<'EOF'
[Unit]
Description=MariaDB database server
After=network.target

[Service]
Type=simple
User=mysql
ExecStart=/usr/local/mariadb/bin/mariadbd --defaults-file=/etc/mysql/my.cnf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable --now mariadb
ln -sf /usr/local/mariadb/bin/mariadb /usr/bin/mariadb
ln -sf /usr/local/mariadb/bin/mariadbd /usr/sbin/mariadbd

echo "MariaDB установлен и запущен"
echo "Установка завершена!"

# =============================================================================
# Проверка версий
# =============================================================================
echo "Версии:"
echo "OpenSSL: $(openssl version)"
echo "NGINX:   $(nginx -v 2>&1)"
echo "PHP:     $(php -v | head -1)"
echo "MariaDB: $(mariadb --version)"
