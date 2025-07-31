#!/bin/bash
export NVM_DIR="$JENKINS_HOME/software/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install --lts
nvm use --lts
npm install -g pnpm --registry http://192.168.10.10:30380/repository/npm-registry-public/
pnpm install sortablejs
pnpm install --registry http://192.168.10.10:30380/repository/npm-registry-public/
pnpm build
tar -czf dist.tar.gz dist