#!/bin/bash

# Notice
# If you make changes to the /etc/systemd/system/gunicorn.service file
# sudo systemctl daemon-reload
# sudo systemctl restart gunicorn

WHOAMI=$(whoami)
IP=$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -o -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
if [[ "$IP" = "" ]]; then
		IP=$(wget -4qO- "http://whatismyip.akamai.com/")
fi

clear
echo 'Welcome to Set Up Django with Postgres, Nginx and Gunicorn on DigitalOcean'
echo "I need to ask you a few questions before starting the setup."

echo "First I need to know the IPv4 address."
read -p "IP address: " -e -i $IP IP

echo "Next I need to take names and password for Postgresql."
read -p "Database name:" DB_NAME
read -p "Database username:" DB_USERNAME
read -p "Database password:" DB_PASSWORD

echo "Now, I just need some answers for your Django project."
read -p "Project name for Django:" DJANGO_PROJECT_NAME
read -p "Superuser username:" DJANGO_SU_USERNAME
read -p "Superuser email:" DJANGO_SU_EMAIL
read -p "Superuser password:" DJANGO_SU_PASS

echo "Okay, that was all I needed. We are ready to setup your server."
read -n1 -r -p "Press any key to continue..."

export LC_ALL=C

cd
sudo apt-get update
sudo apt-get upgrade
sudo apt-get install python3-pip python3-dev libpq-dev postgresql postgresql-contrib nginx
alias python=python3
alias pip=pip3

# Creating database with Postgresql
sudo echo -e "
CREATE DATABASE $DB_NAME;
CREATE USER $DB_USERNAME WITH PASSWORD '$DB_PASSWORD';
ALTER ROLE $DB_USERNAME SET client_encoding TO 'utf8';
ALTER ROLE $DB_USERNAME SET default_transaction_isolation TO 'read committed';
ALTER ROLE $DB_USERNAME SET timezone TO 'UTC';
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USERNAME;
" > create.sql

sudo -u postgres psql -f create.sql
rm create.sql

# Creating git repository
mkdir /home/$WHOAMI/django
mkdir /home/$WHOAMI/django/repo
cd /home/$WHOAMI/django/repo
mkdir site.git
cd site.git
git init --bare

cd hooks
echo -e "
#!/bin/sh
git --work-tree=/home/$WHOAMI/django/$DJANGO_PROJECT_NAME --git-dir=/home/$WHOAMI/django/repo/site.git checkout -f
" > post-receive
chmod +x post-receive

# Creating base django project
mkdir /home/$WHOAMI/django/$DJANGO_PROJECT_NAME
cd /home/$WHOAMI/django/$DJANGO_PROJECT_NAME


sudo pip install virtualenv
cd /home/$WHOAMI/django/$DJANGO_PROJECT_NAME
virtualenv env
source env/bin/activate

pip install django gunicorn psycopg2

django-admin.py startproject $DJANGO_PROJECT_NAME .

python manage.py makemigrations
python manage.py migrate
# django superuser creation
echo "from django.contrib.auth.models import User; User.objects.create_superuser('$DJANGO_SU_USERNAME', '$DJANGO_SU_EMAIL', '$DJANGO_SU_PASS')" | python manage.py shell
python manage.py collectstatic

deactivate

# Creating gunicorn
sudo echo "
[Unit]
Description=gunicorn daemon
After=network.target

[Service]
User=$WHOAMI
Group=www-data
WorkingDirectory=/home/$WHOAMI/django/$DJANGO_PROJECT_NAME
ExecStart=/home/$WHOAMI/django/$DJANGO_PROJECT_NAME/env/bin/gunicorn --access-logfile - --workers 3 --bind unix:/home/$WHOAMI/django/$DJANGO_PROJECT_NAME/$DJANGO_PROJECT_NAME.sock $DJANGO_PROJECT_NAME.wsgi:application

[Install]
WantedBy=multi-user.target
" | sudo tee --append /etc/systemd/system/gunicorn.service

sudo systemctl start gunicorn
sudo systemctl enable gunicorn


# Creating nginx
sudo echo "
server {
    listen 80;
    server_name $IP;

    location = /favicon.ico { access_log off; log_not_found off; }
    location /static/ {
        root /home/$WHOAMI/django/$DJANGO_PROJECT_NAME;
    }
    location /media/ {
        root /home/$WHOAMI/django/$DJANGO_PROJECT_NAME;
    }
    location / {
        include proxy_params;
        proxy_pass http://unix:/home/$WHOAMI/django/$DJANGO_PROJECT_NAME/$DJANGO_PROJECT_NAME.sock;
    }
}" | sudo tee --append /etc/nginx/sites-available/$DJANGO_PROJECT_NAME


sudo ln -s /etc/nginx/sites-available/$DJANGO_PROJECT_NAME /etc/nginx/sites-enabled

sudo nginx -t

sudo systemctl restart nginx

sudo ufw allow 'Nginx Full'


# Finish
# clear
echo "You Can Deploy Repository Here;"
echo "git remote add live ssh://$WHOAMI@$IP/home/$WHOAMI/django/repo/site.git"
