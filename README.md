# Token propagation example workflow
This projects aims to demonstate how to configure a workflow to enable token propagation

# Prerequisites
RHDH 1.5 and Orchestrator 1.5 supporting at least https://github.com/redhat-developer/rhdh-plugins/pull/509

If your current installation does not support the changes introduced by the PR, you can run locally the Orchestrator backend plugin from https://github.com/redhat-developer/rhdh-plugins/tree/main/workspaces/orchestrator#contributors and point to a DataIndex/RHDH in which the workflow will be (or is already) deployed.

## Keycloak

In order to have the token propagation working, we need an OIDC provider. In this example it is Keycloak.
We will install it using the Operator Hub.

If you already have a Keycloak instance, you can skip this section.

* Follow https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/22.0/html/operator_guide/installation-

No need to follow the other steps of the above document as we will use http protocol to reduce the complexity. This should never be done in PRODUCTION, only for DEV pruposes.

* Create the PSQL databse:
```
PSQL_USER=testuser
PSQL_PASSWORD=testpassword

echo "apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql-db
spec:
  serviceName: postgresql-db-service
  selector:
    matchLabels:
      app: postgresql-db
  replicas: 1
  template:
    metadata:
      labels:
        app: postgresql-db
    spec:
      containers:
        - name: postgresql-db
          image: postgres:latest
          volumeMounts:
            - mountPath: /data
              name: cache-volume
          env:
            - name: POSTGRES_USER
              value: ${PSQL_USER}
            - name: POSTGRES_PASSWORD
              value: ${PSQL_PASSWORD}
            - name: PGDATA
              value: /data/pgdata
            - name: POSTGRES_DB
              value: keycloak
      volumes:
        - name: cache-volume
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-db
spec:
  selector:
    app: postgresql-db
  type: LoadBalancer
  ports:
  - port: 5432
    targetPort: 5432" | oc apply -f -
```
* Create Keycloak secret to access the created DB:
```
oc create secret generic keycloak-db-secret \
  --from-literal=username=${PSQL_USER} \
  --from-literal=password=${PSQL_PASSWORD}
```
* Create the Keycloak manifest:
```
echo "apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: example-kc
spec:
  instances: 1
  db:
    vendor: postgres
    host: postgres-db
    usernameSecret:
      name: keycloak-db-secret
      key: username
    passwordSecret:
      name: keycloak-db-secret
      key: password
  http:
    enabled: true
  hostname:
    strict: false" | oc apply -f -
```
* Get the temporary admin credentials to log into the Keycloakl admin console:
```
oc get secret example-kc-initial-admin -o jsonpath='{.data.username}' | base64 --decode
oc get secret example-kc-initial-admin -o jsonpath='{.data.password}' | base64 --decode
```
* Port-forward the keycloak service to be able to access the admin console
```
oc port-forward service/example-kc-service 8080:8080 -n keycloak
```

Now you can log into the Keycloak admin console and create a new realm and a new client in it. We used `quarkus` as realm name and then we created a client `quarkus-app` in it.

You may want to create a permanent admin (from the master realm) user.


## Installation

To build the workflow image and push it to the image registry, use the [./scripts/build.sh](../scripts/build.sh) script:
```bash
This script performs the following tasks in this specific order:
1. Generates a list of Operator manifests for a SonataFlow project using the kn-workflow plugin (requires at least v1.35.0)
2. Builds the workflow image using podman or docker
3. Optionally, deploys the application:
    - Pushes the workflow image to the container registry specified by the image path
    - Applies the generated manifests using kubectl in the current k8s namespace

Usage: 
    ./scripts/build.sh [flags]

Flags:
    -i|--image=<string> (required)       The full container image path to use for the workflow, e.g: quay.io/orchestrator/demo.
    -b|--builder-image=<string>          Overrides the image to use for building the workflow image.
    -r|--runtime-image=<string>          Overrides the image to use for running the workflow.
    -n|--namespace=<string>              The target namespace where the manifests will be applied. Default: current namespace.
    -m|--manifests-directory=<string>    The operator manifests will be generated inside the specified directory. Default: 'manifests' directory in the current directory.
    -w|--workflow-directory=<string>     Path to the directory containing the workflow's files (the 'src' directory). Default: current directory.
    -P|--no-persistence                  Skips adding persistence configuration to the sonataflow CR.
       --deploy                          Deploys the application.
    -h|--help                            Prints this help message.

Notes: 
    - This script respects the 'QUARKUS_EXTENSIONS' and 'MAVEN_ARGS_APPEND' environment variables.
```

1. Build the image and generate the manifests from workflow's directory (replace the target image):
```
../scripts/build.sh --image=quay.io/orchestrator/example-token-propagation
```

The manifests location will be displayed by the script, or at the given location by the `--manifests-directory` flag
2. Push the image
```
POCKER=$(command -v podman || command -v docker) "$@"
$POCKER push <image>
```

3. Apply the manifests:
The generated manifests from the previous commands are included in this repository at `./workflow/manifests`.
```
TARGET_NS=sonataflow-infra
oc -n ${TARGET_NS} create -f .
```

All the previous steps can be done together by running:
```
../../scripts/build.sh --image=quay.io/orchestrator/example-token-propagation --deploy
```

Once the manifests are deployed, set the environements variables needed.

## Try it
First you need to deploy the dumber-server that will print all headers from incoming requests:
```
oc apply -f resources/dumb_server/00-deploy.yaml -n sontaflow-infra
```
You can rebuild the image of the dumb-server using the [Dockerfile](resources/dumb_server/Dockerfile) and the [source script](resources/dumb_server/dumber-server.py).

To execute the workflow without passing by the RHDH UI, you may use the following request:
```
export RHDH_BEARER_TOKEN=$(oc get secrets -n rhdh-operator backstage-backend-auth-secret -o go-template='{{ .data.BACKEND_SECRET  }}' | base64 -d)

curl -v -XPOST -H "Content-type: application/json" -H "Authorization: ${RHDH_BEARER_TOKEN}" ${RHDH_ROUTE}/api/orchestrator/v2/workflows/token-propagation/execute -d '{"inputData":{}, "authTokens": [{"provider": "First", "token": "FIRST"}, {"provider": "Other", "token": "OTHER"}]}'
```

To generate a real token for an user in the Keycloak:
```
export access_token=$(\
    curl  -X POST http://localhost:8080/realms/${REALM}/protocol/openid-connect/token \
    --user ${CLIENT_ID}:${CLIENT_SECRET} \
    -H 'content-type: application/x-www-form-urlencoded' \
    -d 'username=${USERNAME}&password=${PASSWORD}&grant_type=password' | jq --raw-output '.access_token' \
)
```

If you are running locally, `RHDH_BEARER_TOKEN` must be updated with the content of https://github.com/redhat-developer/rhdh-plugins/blob/main/workspaces/orchestrator/app-config.yaml#L16:
```
export RHDH_BEARER_TOKEN='Bearer <base64 encoded token from config>'
```

Then check the logs for the `dumber-server` pod:
```
================ Headers for /first ================
2025-04-04 14:34:23.400634
Accept: application/json
Authorization: Bearer FIRST
Kogitoprocid: token-propagation
Kogitoprocinstanceid: 25303ddb-88a0-4d12-84e4-7475d62bfcff
Kogitoprocist: Active
Kogitoproctype: SW
Kogitoprocversion: 1.0
Host: dumber-server-service.sonataflow-infra
Connection: Keep-Alive
User-Agent: Apache-HttpClient/4.5.14.redhat-00012 (Java/17.0.13)
================ END ================
================ Headers for /other ================
2025-04-04 14:34:23.460084
Accept: application/json
Authorization: Bearer OTHER3
Kogitoprocid: token-propagation
Kogitoprocinstanceid: 25303ddb-88a0-4d12-84e4-7475d62bfcff
Kogitoprocist: Active
Kogitoproctype: SW
Kogitoprocversion: 1.0
Host: dumber-server-service.sonataflow-infra
Connection: Keep-Alive
User-Agent: Apache-HttpClient/4.5.14.redhat-00012 (Java/17.0.13)
================ END ================
```