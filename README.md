# Secure AWS Instance Profiles on DC/OS
Security is always an important topic in today's distributed systems. With DC/OS Enterprise, we offer a feature called DC/OS Secrets, which makes it possible to inject secure information like passwords or cryptographic keys into your application. No other application is able to read or change this information, and with DC/OS Identity and Access Management ( IAM ) you can also restrict the group of users that have access to this information.

## The usual workflow
Let's assume you have an application that wants to access AWS resources, like an S3 bucket. With [Secrets](https://docs.d2iq.com/mesosphere/dcos/1.13/security/ent/secrets/), you can easily create an IAM user and assign it a Policy which is able to access your particular bucket. You take the `ACCESS_KEY` and add it to your Marathon specification, then store the `SECRET_ACCESS_KEY` into a DC/OS Secret in your default vault which you also specify in your Marathon application. This practice is not bad, but it means you must rotate these credentials on a regular basis and therefore you need to update your application from time to time.

## AWS Agents can do better
If your agents are already running on AWS Instances, there is a way better and best practice solution to this problem: Instance Profiles. [Instance profiles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html) allow you to assign Roles to Instances. The AWS SDK running on an AWS Instance will try to retrieve credentials from the [AWS Metadata API](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html). The huge benefit of this is that you do not need to rotate credentials by yourself, as AWS takes care of it. These credentials will have a short lifetime, so even if they get leaked a user will only have a certain amount of time to use them.

## Not every task should have this privilege
On DC/OS, multiple applications will share the same agent and therefore share the same instance profile. This sharing is something that you should avoid. In the initially described process, you only hand out the users credentials to the applications that you’ve selected, so you decide based on the secret containing the credentials which application gets the credentials.

## AssumeRole and external_id
We can combine the security of instance profiles with the selective authorization of DC/OS secrets. AWS offers a process called [AssumeRole](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html). With this process, a Role (Instance,User) is able to retrieve temporary credentials for another Role (even in other AWS accounts). So, in our example, the Instance would assume a Role that has access to the S3 bucket. This process alone does not really change the authorization problem, as every application would still be able to use it, but AWS gives an additional layer of security to this procedure called [external_id](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-user_externalid.html). The `external_id` is a Pre-Shared-Key (PSK) added to the trust relationship of a role which allows us to assume this role. This PSK will allow us to use DC/OS Secrets acting as an authorization instance for our application by placing an AssumeRole configuration that includes the `external_id`.

## Example
[This repository](https://github.com/fatz/dcos-secure-instance-profiles) contains a [main.tf](https://github.com/fatz/dcos-secure-instance-profiles/blob/master/main.tf) with an example setup. You only need to place a DC/OS license in your home folder ( `$HOME/license.txt` ) and the public key file of the SSH-Key you've loaded into your ssh-agent at `~/.ssh/id_rsa.pub`. If these files are at different locations, just edit the `main.tf` and change the path for your environment.

### Creating the cluster
Once you've downloaded all the files of this repository ( `git clone https://github.com/fatz/dcos-secure-instance-profiles && cd dcos-secure-instance-profiles` ), you will need to initialize terraform and start creating the cluster.

Before you start creating the cluster, make sure your AWS setup is finished and working. Either `$AWS_PROFILE` needs to be set to the profile you want to use or make sure that you've properly set up your aws cli `aws configure`. To ensure you are using the correct account, you should run `aws sts get-caller-identity` and see the account id that you will be using.


```bash
terraform init -upgrade .
terraform apply
```

### If not already done, download the dcos-cli

```bash
# on OSX
brew install dcos-cli

# on linux

```

### Attach to cluster
After successfully creating the cluster, we have to attach to the cluster;

```bash
# in this setup we have to use --insecure as we did not give the load balancer a ACM cert and so it is an self signed one.
dcos cluster setup $(terraform output masters_dns_name) --password=deleteme --username=bootstrapuser --insecure
```

### Ensure enterprise CLI
Let's make sure we have the enterprise features available in our CLI ( this is usually just needed for older versions of DC/OS (cli)):

```bash
dcos package install dcos-enterprise-cli --cli --yes
```

### AWS config secret
We already prepared the aws config for the application in our `main.tf`. Next we create the secret from it:

```bash
dcos security secrets create /instance-profile-app/aws-config -v "$(terraform output secret_aws_conf)"
```

### Install EdgeLB
To access our app, let's install [EdgeLB](https://docs.d2iq.com/mesosphere/dcos/services/edge-lb/). As we’re running strict mode, we have to create a service-account and a service-account-secret

#### Prepare service account and secret

```bash
dcos security org service-accounts keypair edge-lb-private-key.pem edge-lb-public-key.pem
dcos security org service-accounts create -p edge-lb-public-key.pem -d "Edge-LB service account" edge-lb-principal
dcos security secrets create-sa-secret --strict edge-lb-private-key.pem edge-lb-principal dcos-edgelb/edge-lb-secret
dcos security org groups add_user superusers edge-lb-principal
```

#### Install and configure EdgeLB
```bash
echo '{"service": {"secretName": "dcos-edgelb/edge-lb-secret","principal": "edge-lb-principal","mesosProtocol": "https"}}' | dcos package install edgelb --options=/dev/stdin --yes
```

And wait for EdgeLB to respond:

```bash
until dcos edgelb ping; do sleep 1; done
```

### Deploy the marathon app
The last step is to finally deploy our simple app using the bucket that we've prepared. We’re using the template given in our terraform file. You can review it simply by using the terraform output marathon_app_definition.

```bash
terraform output marathon_app_definition | dcos marathon app add
```

As we are using [EdgeLB AutoPool](http://docs-review.mesosphere.com/mesosphere/dcos/services/edge-lb/1.5/tutorials/auto-pools/) feature lets wait for the pool to come up:
```bash
until dcos edgelb status auto-default; do sleep 1; done
```

Let's ensure our app became healthy meanwhile:

```bash
until dcos marathon app show /instance-profile-app | jq -e .tasksHealthy==1 >/dev/null; do echo "waiting for app becoming healthy" && sleep 10;done
```

## Using the app
Once the app is healthy, we can post data to it with curl.

```bash
echo "foobar" | curl --user testuser:password -X POST -H "Host: binapp.mesosphere.com" -d @- $(terraform output public-agents-loadbalancer)/bin
```

This app is creating an ID for the posted content. With this ID, it is storing the content into the specified bucket. So, we can now use the aws-cli to see if it has worked for us. Please replace in the URL with the id you received from the command above.

```bash
aws s3 cp s3://$(terraform output s3_bucket_name)/bin/<id returned by the post> -
```

You can see that there is a file in the s3 bucket and its content is what we posted above.

All of this is based on Instance Profile and AssumeRole without any static credentials but the external_id, which only works in combination with the Account and Role of our DC/OS cluster.

You can tinker around with this technique and it's even more valuable if you're running an AWS multi-account setup.
