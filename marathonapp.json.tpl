{
  "env": {
    "AWS_CONFIG": {
      "secret": "secret0"
    },
    "BINAPP_BUCKET": "${s3_bucket_name}",
    "BINAPP_USER": "testuser",
    "BINAPP_PATH": "/bin",
    "AWS_REGION": "us-east-1",
    "AWS_CONFIG_FILE": "/tmp/awsconfig",
    "BINAPP_PASS": "password"
  },
  "labels": {
    "edgelb.expose": "true",
    "edgelb.template": "default",
    "edgelb.first.frontend.rules": "hostEq:binapp.mesosphere.com"
  },
  "id": "/instance-profile-app",
  "backoffFactor": 1.15,
  "backoffSeconds": 1,
  "cmd": "echo -e \"$${AWS_CONFIG}\" > /tmp/awsconfig && ./main",
  "container": {
    "portMappings": [
      {
        "containerPort": 8000,
        "hostPort": 0,
        "protocol": "tcp",
        "servicePort": 10101,
        "name": "s3apphttp"
      }
    ],
    "type": "DOCKER",
    "volumes": [],
    "docker": {
      "image": "fatz/s3bin:0.0.2",
      "forcePullImage": true,
      "privileged": false,
      "parameters": []
    }
  },
  "cpus": 0.1,
  "disk": 0,
  "healthChecks": [
    {
      "gracePeriodSeconds": 300,
      "intervalSeconds": 60,
      "maxConsecutiveFailures": 3,
      "portIndex": 0,
      "timeoutSeconds": 20,
      "delaySeconds": 15,
      "protocol": "MESOS_HTTP",
      "path": "/ping",
      "ipProtocol": "IPv4"
    }
  ],
  "instances": 1,
  "maxLaunchDelaySeconds": 300,
  "mem": 128,
  "gpus": 0,
  "networks": [
    {
      "mode": "container/bridge"
    }
  ],
  "requirePorts": false,
  "secrets": {
    "secret0": {
      "source": "instance-profile-app/aws-config"
    }
  },
  "upgradeStrategy": {
    "maximumOverCapacity": 1,
    "minimumHealthCapacity": 1
  },
  "killSelection": "YOUNGEST_FIRST",
  "unreachableStrategy": {
    "inactiveAfterSeconds": 0,
    "expungeAfterSeconds": 0
  },
  "fetch": [],
  "constraints": []
}
