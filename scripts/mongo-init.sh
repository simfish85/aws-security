#!/bin/bash
sudo apt-get update
sudo apt install mongodb -y
sudi apt install awscli -y
mongo --eval 'db.addUser({user: "${mongodb_user}", pwd: "${mongodb_password}", roles: ["root"]})'