#!/bin/bash
export NVM_DIR="$JENKINS_HOME/software/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install --lts
nvm use --lts
npm install -g yarn --registry http://192.168.10.10:30380/repository/npm-registry-public/
yarn --registry http://192.168.10.10:30380/repository/npm-registry-public/
pnpm build:prod
tar -czf dist.tar.gz dist