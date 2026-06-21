export $(cat open5gs/open5gs.env | xargs) && envsubst < open5gs/open5gs-5gc.template.yml > open5gs/
open5gs-5gc.yml