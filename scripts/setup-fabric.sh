#!/bin/bash
#
# Copyright IBM Corp. All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#

#
# This script does the following:
# 1) registers orderer and peer identities with intermediate fabric-ca-servers
# 2) Builds the channel artifacts (e.g. genesis block, etc)
#

function main {
   log "Beginning building channel artifacts ..."
   registerIdentities
   getCACerts
   makeConfigTxYaml
   generateChannelArtifacts
   log "Finished building channel artifacts"
   generateBftConfig
   touch /$SETUP_SUCCESS_FILE
}

# Enroll the CA administrator
function enrollCAAdmin {
   waitPort "$CA_NAME to start" 90 $CA_LOGFILE $CA_HOST 7054
   log "Enrolling with $CA_NAME as bootstrap identity ..."
   export FABRIC_CA_CLIENT_HOME=$HOME/cas/$CA_NAME
   export FABRIC_CA_CLIENT_TLS_CERTFILES=$CA_CHAINFILE
   fabric-ca-client enroll -d -u https://$CA_ADMIN_USER_PASS@$CA_HOST:7054
}

function registerIdentities {
   log "Registering identities ..."
   registerOrdererIdentities
   registerPeerIdentities
}

# Register any identities associated with the orderer
function registerOrdererIdentities {
   for ORG in $ORDERER_ORGS; do
      initOrgVars $ORG
      enrollCAAdmin
      local COUNT=1
      while [[ "$COUNT" -le $NUM_ORDERERS ]]; do
         initOrdererVars $ORG $COUNT
         log "Registering $ORDERER_NAME with $CA_NAME"
         fabric-ca-client register -d --id.name $ORDERER_NAME --id.secret $ORDERER_PASS --id.type orderer
         COUNT=$((COUNT+1))
      done
      log "Registering admin identity with $CA_NAME"
      # The admin identity has the "admin" attribute which is added to ECert by default
      fabric-ca-client register -d --id.name $ADMIN_NAME --id.secret $ADMIN_PASS --id.attrs "admin=true:ecert"
   done
}

# Register any identities associated with a peer
function registerPeerIdentities {
   for ORG in $PEER_ORGS; do
      initOrgVars $ORG
      enrollCAAdmin
      local COUNT=1
      while [[ "$COUNT" -le $NUM_PEERS ]]; do
         initPeerVars $ORG $COUNT
         log "Registering $PEER_NAME with $CA_NAME"
         fabric-ca-client register -d --id.name $PEER_NAME --id.secret $PEER_PASS --id.type peer
         COUNT=$((COUNT+1))
      done
      log "Registering admin identity with $CA_NAME"
      # The admin identity has the "admin" attribute which is added to ECert by default
      fabric-ca-client register -d --id.name $ADMIN_NAME --id.secret $ADMIN_PASS --id.attrs "hf.Registrar.Roles=client,hf.Registrar.Attributes=*,hf.Revoker=true,hf.GenCRL=true,admin=true:ecert,abac.init=true:ecert"
      log "Registering user identity with $CA_NAME"
      fabric-ca-client register -d --id.name $USER_NAME --id.secret $USER_PASS
   done
}

function getCACerts {
   log "Getting CA certificates ..."
   for ORG in $ORGS; do
      initOrgVars $ORG
      log "Getting CA certs for organization $ORG and storing in $ORG_MSP_DIR"
      export FABRIC_CA_CLIENT_TLS_CERTFILES=$CA_CHAINFILE
      fabric-ca-client getcacert -d -u https://$CA_HOST:7054 -M $ORG_MSP_DIR
      finishMSPSetup $ORG_MSP_DIR
      # If ADMINCERTS is true, we need to enroll the admin now to populate the admincerts directory
      if [ $ADMINCERTS ]; then
         switchToAdminIdentity
      fi
   done
}

# printOrg
function printOrg {
   echo "
  - &$ORG_CONTAINER_NAME

    Name: $ORG

    # ID to load the MSP definition as
    ID: $ORG_MSP_ID

    # MSPDir is the filesystem path which contains the MSP configuration
    MSPDir: $ORG_MSP_DIR"
}

# printOrdererOrg <ORG>
function printOrdererOrg {
   initOrgVars $1
   printOrg
}

# printPeerOrg <ORG> <COUNT>
function printPeerOrg {
   initPeerVars $1 $2
   printOrg
   echo "
    AnchorPeers:
       # AnchorPeers defines the location of peers which can be used
       # for cross org gossip communication.  Note, this value is only
       # encoded in the genesis block in the Application section context
       - Host: $PEER_HOST
         Port: 7051"
}

function makeConfigTxYaml {
   {
   echo "################################################################################
#
#   Profile
#
#   - Different configuration profiles may be encoded here to be specified
#   as parameters to the configtxgen tool
#
################################################################################
Profiles:

  OrgsOrdererGenesis:
    Orderer:
      <<: *OrdererDefaults
      # Orderer Type: The orderer implementation to start
      # Available types are \"solo\" and \"kafka\"
      OrdererType: bftsmart
"

   echo "
      # Organizations is the list of orgs which are defined as participants on
      # the orderer side of the network
      Organizations:"

   for ORG in $ORDERER_ORGS; do
      initOrgVars $ORG
      echo "        - *${ORG_CONTAINER_NAME}"
   done

   echo "
    Consortiums:

      SampleConsortium:

        Organizations:"

   for ORG in $PEER_ORGS; do
      initOrgVars $ORG
      echo "          - *${ORG_CONTAINER_NAME}"
   done

   echo "
  OrgsChannel:
    Consortium: SampleConsortium
    Application:
      <<: *ApplicationDefaults
      Organizations:"

   for ORG in $PEER_ORGS; do
      initOrgVars $ORG
      echo "        - *${ORG_CONTAINER_NAME}"
   done

   echo "
################################################################################
#
#   Section: Organizations
#
#   - This section defines the different organizational identities which will
#   be referenced later in the configuration.
#
################################################################################
Organizations:"

   for ORG in $ORDERER_ORGS; do
      printOrdererOrg $ORG
   done

   for ORG in $PEER_ORGS; do
      printPeerOrg $ORG 1
   done

   echo "
################################################################################
#
#   SECTION: Application
#
#   This section defines the values to encode into a config transaction or
#   genesis block for application related parameters
#
################################################################################
Application: &ApplicationDefaults

    # Organizations is the list of orgs which are defined as participants on
    # the application side of the network
    Organizations:
"
echo "
Orderer: &OrdererDefaults
    OrdererType: solo

    Addresses:"

for ORG in $ORDERER_ORGS; do
      local COUNT=1
      while [[ "$COUNT" -le $NUM_ORDERERS ]]; do
         initOrdererVars $ORG $COUNT
         echo "        - $ORDERER_HOST:7050"
         COUNT=$((COUNT+1))
      done
   done

echo "
    BatchTimeout: 2s
    BatchSize:
        MaxMessageCount: 10
        AbsoluteMaxBytes: 99 MB
        PreferredMaxBytes: 512 KB
    MaxChannels: 0
    Kafka:
        Brokers:
            - kafka0:9092
            - kafka1:9092
            - kafka2:9092
    #JCS: BFT-SMaRt options
    BFTsmart:

        ConnectionPoolSize: 20

        RecvPort: 9999

    Organizations:
"

   } > /etc/hyperledger/fabric/configtx.yaml
   # Copy it to the data directory to make debugging easier
   cp /etc/hyperledger/fabric/configtx.yaml /$DATA
}

function generateChannelArtifacts() {
  
  which configtxgen
  if [ "$?" -ne 0 ]; then
    fatal "configtxgen tool not found. exiting"
  fi

  log "Generating orderer genesis block at $GENESIS_BLOCK_FILE"
  # Note: For some unknown reason (at least for now) the block file can't be
  # named orderer.genesis.block or the orderer will fail to launch!
 #cp /data/core.yaml $FABRIC_CFG_PATH/
  configtxgen -profile OrgsOrdererGenesis -outputBlock $GENESIS_BLOCK_FILE
  if [ "$?" -ne 0 ]; then
    fatal "Failed to generate orderer genesis block"
  fi

  log "Generating channel configuration transaction at $CHANNEL_TX_FILE"
  configtxgen -profile OrgsChannel -outputCreateChannelTx $CHANNEL_TX_FILE -channelID $CHANNEL_NAME
  if [ "$?" -ne 0 ]; then
    fatal "Failed to generate channel configuration transaction"
  fi

  for ORG in $PEER_ORGS; do
     initOrgVars $ORG
     log "Generating anchor peer update transaction for $ORG at $ANCHOR_TX_FILE"
     configtxgen -profile OrgsChannel -outputAnchorPeersUpdate $ANCHOR_TX_FILE \
                 -channelID $CHANNEL_NAME -asOrg $ORG
     if [ "$?" -ne 0 ]; then
        fatal "Failed to generate anchor peer update for $ORG"
     fi
  done
}
function generateBftConfig() {
KEYFILE=""
SIGN_FILE=""
for entry in `ls /data/orgs/org0/admin/msp/keystore/`; do
    KEYFILE=${entry}
done
for entry in `ls /data/orgs/org0/admin/msp/signcerts/`; do
    SIGN_FILE=${entry}
done
echo "#The ID of the membership service provider (MSP)
MSPID=org0MSP

#Certificate of the node, compliant to Fabric's MSP guidelines
CERTIFICATE=/opt/gopath/src/github.com/hyperledger/hyperledger-bftsmart-release-1.1/config/peer.pem

#Private key of the node, compliant to Fabric's MSP guidelines
PRIVKEY=/opt/gopath/src/github.com/hyperledger/hyperledger-bftsmart-release-1.1/config/key.pem

#Number of signer/sending threads in the pool
PARELLELISM=10

#Maximum number of blocks to submit to each signer/sending thread
BLOCKS_PER_THREAD=10000

#IDs of the frontends present in the system, separate by commas
RECEIVERS=1000,2000
" > /data/node.config
cat /data/orgs/org0/admin/msp/keystore/$KEYFILE > /data/key.pem
cat /data/orgs/org0/admin/msp/signcerts/$SIGN_FILE > /data/peer.pem
echo "
0 replica-0 11000
1 replica-1 11010
2 replica-2 11020
3 replica-3 11030
4 127.0.0.1 11040
5 127.0.0.1 11050
6 127.0.0.1 11060
7 127.0.0.1 11070
7001 127.0.0.1 11100
" > /data/hosts.config
}

set -e

SDIR=$(dirname "$0")
source $SDIR/env.sh

main
