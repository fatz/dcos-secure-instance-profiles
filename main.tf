provider "aws" {}

# Used to determine your public IP for forwarding rules
data "http" "whatismyip" {
  url = "http://whatismyip.akamai.com/"
}

# lets create a random string for unique cluster and bucket name
resource "random_string" "cluster" {
  upper   = false
  length  = 4
  special = false
}

locals {
  cluster_name = "securedcos-${random_string.cluster.result}"
}

module "dcos" {
  source  = "dcos-terraform/dcos/aws"
  version = "~> 0.2.0"

  providers = {
    aws = "aws"
  }

  cluster_name        = "${local.cluster_name}"
  ssh_public_key_file = "~/.ssh/id_rsa.pub"
  admin_ips           = ["${data.http.whatismyip.body}/32"]

  num_masters        = "1"
  num_private_agents = "1"
  num_public_agents  = "1"

  dcos_variant              = "ee"
  dcos_security             = "strict"
  dcos_version              = "2.0.3"
  dcos_license_key_contents = "${file("~/license.txt")}"

  # provide a SHA512 hashed password, here "deleteme"
  dcos_superuser_password_hash = "$6$rounds=656000$YSvuFmasQDXheddh$TpYlCxNHF6PbsGkjlK99Pwxg7D0mgWJ.y0hE2JKoa61wHx.1wtxTAHVRHfsJU9zzHWDoE08wpdtToHimNR9FJ/"
  dcos_superuser_username      = "bootstrapuser"
}

output "masters_dns_name" {
  description = "This is the load balancer address to access the DC/OS UI"
  value       = "${module.dcos.masters-loadbalancer}"
}

# Lets create a bucket we want to use with out application
resource "aws_s3_bucket" "b" {
  bucket = "dcos-secure-instance-profiles-app-${random_string.cluster.result}"
  acl    = "private"

  force_destroy = true
}

output "s3_bucket_name" {
  value = "${aws_s3_bucket.b.bucket}"
}

# create a policy allowing the application access to the bucket
data "aws_iam_policy_document" "app-bucket-access" {
  statement {
    sid = "1"

    actions = [
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
    ]

    resources = [
      "arn:aws:s3:::*",
    ]
  }

  statement {
    actions = [
      "s3:ListBucket",
    ]

    resources = [
      "arn:aws:s3:::${aws_s3_bucket.b.bucket}",
    ]
  }

  statement {
    actions = [
      "s3:*",
    ]

    resources = [
      "arn:aws:s3:::${aws_s3_bucket.b.bucket}/",
      "arn:aws:s3:::${aws_s3_bucket.b.bucket}/*",
    ]
  }
}

# create the policy we want to use in our role.
resource "aws_iam_policy" "app-bucket-access" {
  name   = "${local.cluster_name}-app-bucket-access"
  path   = "/"
  policy = "${data.aws_iam_policy_document.app-bucket-access.json}"
}

# We need to know the role arn of our private agent instance profile.
# Currently there is no output for it. This will be changed soon
data "aws_instance" "agent1" {
  instance_id = "${element(module.dcos.infrastructure.private_agents.instances, 0)}"
}

data "aws_iam_instance_profile" "agent-instance-profile" {
  name = "${data.aws_instance.agent1.iam_instance_profile}"
}

data "aws_iam_policy_document" "agent-assume-role-policy" {
  statement {
    actions   = ["sts:AssumeRole"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "assume-role-policy" {
  name   = "${local.cluster_name}-agent-assume-role-policy"
  path   = "/"
  policy = "${data.aws_iam_policy_document.agent-assume-role-policy.json}"
}

resource "aws_iam_role_policy_attachment" "assume-role-policy-attachment" {
  role       = "${data.aws_iam_instance_profile.agent-instance-profile.role_name}"
  policy_arn = "${aws_iam_policy.assume-role-policy.arn}"
}

#########

# lets create a random string for our external_id PSK
resource "random_string" "external_id" {
  length  = 25
  special = false
}

# This is the assume role policy. It creates the trust between the role used in our instance
# profile and the role we want to create for our application
data "aws_iam_policy_document" "instance-assume-role-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["${data.aws_iam_instance_profile.agent-instance-profile.role_arn}"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = ["${random_string.external_id.result}"]
    }
  }
}

# Creating the role and putting the things together. Our role is using the above assume role
# policy to trust our private agents.
resource "aws_iam_role" "instance-profile-app" {
  name               = "${local.cluster_name}-secure-instance-profiles-app"
  path               = "/"
  assume_role_policy = "${data.aws_iam_policy_document.instance-assume-role-policy.json}"
}

data "aws_caller_identity" "current" {}

# Finally we attach the policy giving access to the s3 bucket to our role the app should
# assume into.
resource "aws_iam_policy_attachment" "instance-profile-app-policy-attachment" {
  name       = "${local.cluster_name}-instance-profile-app-policy-attachment"
  roles      = ["${aws_iam_role.instance-profile-app.name}"]
  policy_arn = "${aws_iam_policy.app-bucket-access.arn}"
}

locals {
  secret_aws_conf = <<EOF
[default]
region = us-east-1
role_arn = ${aws_iam_role.instance-profile-app.arn}
external_id = ${random_string.external_id.result}
credential_source = Ec2InstanceMetadata
EOF
}

data "template_file" "marathon_app_definition" {
  vars {
    s3_bucket_name = "${aws_s3_bucket.b.bucket}"
  }

  template = "${file("${path.module}/marathonapp.json.tpl")}"
}

output "secret_aws_conf" {
  value = "${local.secret_aws_conf}"
}

output "marathon_app_definition" {
  value = "${data.template_file.marathon_app_definition.rendered}"
}

output "public-agents-loadbalancer" {
  value = "${module.dcos.public-agents-loadbalancer}"
}
