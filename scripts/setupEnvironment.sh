#!/bin/bash
cp /etc/ssl/certs2/federationHQ-CA.pem /etc/pki/ca-trust/source/anchors/
update-ca-trust
