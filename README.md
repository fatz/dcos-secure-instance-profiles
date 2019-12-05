# Secure AWS Instance Profiles on DC/OS
Security is always an important topic in today's distributed systems. With DC/OS Enterprise we offer a feature called DC/OS Secrets. With Secrets it is possible to inject secure information like passwords or cryptographic keys into your application. No other Application is able to read or change this information and with DC/OS IAM you can also strip down the group of users having access to this information.

## The usual workflow
Let's assume you have an application that wants to access AWS resources, like a S3 bucket. With Secrets you can easily create an IAM user and assign it a Policy which is able to access your particular bucket. You take the ACCESS_KEY and add it to your Marathon specification and store the SECRET_ACCESS_KEY into a DC/OS Secret in your default vault which you also specify in your marathon application. This is absolutely not bad but it means you have to rotate these credentials on a regular basis and therefore you need to update your application from time to time.

## AWS Agents can do better
If your agents are already running on AWS Instances there is a way better and best practise solution solving your problem: Instance Profiles. Instance profiles allow you to assign Roles to Instances. The AWS SDK will realise running on an AWS Instance and try to retrieve credentials from the AWS Metadata API. The huge benefit of this is you do not need to rotate credentials by yourself as AWS is taking care of it. These credentials will have a short live time so even if they get leaked a user will only have a certain amount of time to use those credentials.

## Not every task should have this privilege
In DC/OS multiple applications will share the same agent and therefore share the same instance profile. This is something you might want to avoid. With the initially described process you only hand out the users credentials to the applications you’ve selected, so you decide based on the secret containing the credentials which application gets the creds.

## AssumeRole and external_id
We can combine the security of instance profiles with the selective authorization of DC/OS secrets. AWS offers a process called AssumeRole. With this a Role (Instance,User) is able to retrieve temporary credentials for another role ( even other accounts are possible ).
So in our example the Instance would Assume into the Role having access to the S3 bucket.
This process alone does not really change the authorization problem as still every application would be able to use it but AWS gives an additional layer of security to this procedure: external_id. The external_id is a pre-shared-key added to the trust relationship of a role which allows us to assume into it.
This PSK will allow us to use DC/OS Secrets acting as authorization instance for our application by placing an AssumeRole configuration including the external_id.

## Example
[This repository](https://github.com/fatz/dcos-secure-instance-profiles) contains a [main.tf](./main.tf) with a example setup. You only need to place a DC/OS license in your Homefolder ( `$HOME/license.txt` ) and the public key file of the SSH-Key you've loaded into your ssh-agent at `~/.ssh/id_rsa.pub`. If these files are at different locations just edit the `main.tf` and change the path for your environment.

### Creating the cluster
Once you've downloaded all the files of this repository ( `git clone https://github.com/fatz/dcos-secure-instance-profiles && cd dcos-secure-instance-profiles` ) you need to initialize terraform and start creating the cluster

Before you start creating the cluster make sure your AWS setup is finished and working. Either `$AWS_PROFILE` needs to be set to the profile you want to use or make sure you've properly setup your aws cli `aws configure`. To ensure you will use the expected account you can run `aws sts get-caller-identity` and see the account id you will be using.

```bash
terraform init -upgrade .
terraform apply
```

### If not already done download the dcos-cli

```bash
# on OSX
brew install dcos-cli

# on linux

```

### Attach to cluster
After successfully creating the cluster we have to attach to the cluster

```bash
# in this setup we have to use --insecure as we did not give the load balancer a ACM cert and so it is an self signed one.
dcos cluster setup $(terraform output masters_dns_name) --password=deleteme --username=bootstrapuser --insecure
```

### Ensure enterprise CLI
Lets make sure we have the enterprise features available in our CLI ( this is usually just needed for older versions of DC/OS (cli))

```bash
dcos package install dcos-enterprise-cli --cli --yes
```

### AWS config secret
We already prepared the aws config for the application in our `main.tf`. Next we create the secret from it.

```bash
dcos security secrets create /instance-profile-app/aws-config -v "$(terraform output secret_aws_conf)"
```

### Install marathon-lb
To access our app lets install marathon-lb. As we’re running strict mode we’ve to create a service-account and a service-account-secret

#### Prepare service account and secret

```bash
dcos security org service-accounts keypair mlb-private-key.pem mlb-public-key.pem
dcos security org service-accounts create -p mlb-public-key.pem -d "Marathon-LB service account" marathon-lb-sa
dcos security secrets create-sa-secret --strict mlb-private-key.pem marathon-lb-sa marathon-lb/service-account-secret
dcos security org users grant marathon-lb-sa dcos:service:marathon:marathon:services:/ read
dcos security org users grant marathon-lb-sa dcos:service:marathon:marathon:admin:events read --description "Allows access to Marathon events"
```

#### Install marathon-lb
```bash
echo '{"marathon-lb": {"secret_name": "marathon-lb/service-account-secret","marathon-uri": "https://marathon.mesos:8443"}}' | dcos package install marathon-lb --options=/dev/stdin --yes
```

### Deploy the marathon app
The last step is to finally deploy our simple app using the bucket we prepared. We’re using the template given in our terraform file. You can simply review it using terraform output marathon_app_definition.

```bash
terraform output marathon_app_definition | dcos marathon app add
```

Lets wait for the app to become healthy

```bash
until dcos marathon app show /instance-profile-app | jq -e .tasksHealthy==1 >/dev/null; do echo "waiting for app becoming healthy" && sleep 10;done
```

## Using the app
Once the app is healthy we can post data with curl to it.

```bash
echo "foobar" | curl --user testuser:password -X POST -H "Host: binapp.mesosphere.com" -d @- $(terraform output public-agents-loadbalancer)/bin
```

This app is creating an ID for the posted content. With this ID its storing the content into the specified bucket. So we can now use the aws-cli to see if it worked for us. Please replace <id returned by the post> in the URL with the id you received from the command above.

```bash
aws s3 cp s3://$(terraform output s3_bucket_name)/bin/<id returned by the post> -
```

You see that there is a file in the s3 bucket and its content is the one we posted above.

All this is based on Instance Profile and AssumeRole without any static credentials but the external_id which only works in combination the the Account and Role of our DC/OS cluster.

You can tinker around with this technique and its even more valuable if you're running an AWS multi-account setup.
