# TODO tezos/tezos#2170: search shifted protocol name/no; rename script
trap 'exit $?' ERR
set -x
cd
# [install docker]
apt-get update
apt-get install -y docker.io docker-compose kmod wget
dockerd &
# [get granadanet]
wget -O granadanet.sh https://gitlab.com/tezos/tezos/raw/latest-release/scripts/tezos-docker-manager.sh
chmod +x granadanet.sh
# [start granadanet]
./granadanet.sh start
