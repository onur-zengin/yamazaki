# set the provider region specific to the module
# w/out this definition here, the child module would inherit the working region (us-east-1) from root
provider "aws" {
  region = "eu-west-2"
}

# collect the available AZs and the most recent AMI for the region that are required for the VPCs and EC2 instances, respectively
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

#azs  = data.aws_availability_zones.available.names

data "aws_ami" "amazon_linux" {
  most_recent = true
  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-5.10-hvm-2.0.*-x86_64-gp2"]
  }
  owners = ["amazon"]
}

/*
resource "aws_ec2_transit_gateway" "lon" {
  description = "example"
}
*/


# To provide I'net connectivity to the bastion host in the public subnet. Can be removed in Production
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eu-west-2-vpc-1.id

  tags = {
    Name = "tf_igw"
  }
}

# Note that when the VPC CIDRs are IPAM managed, VPC deletion may take longer than expected (>15mins)
# https://github.com/hashicorp/terraform-provider-aws/issues/31211

resource "aws_vpc" "eu-west-2-vpc-1" {
  ipv4_ipam_pool_id   = var.pool_id
  ipv4_netmask_length = 16
  depends_on = [
    var.cidr_block
  ]

  tags = {
    Name = "tform-1"
  }
}


resource "aws_subnet" "prv-1a" {
  vpc_id                  = aws_vpc.eu-west-2-vpc-1.id
  availability_zone       = "eu-west-2a" // randomly-assigned if not specified
  cidr_block              = cidrsubnet(aws_vpc.eu-west-2-vpc-1.cidr_block, 4, 2)
  map_public_ip_on_launch = false

  tags = {
    Name = "tform_prv-vpc1-a"
  }
}

resource "aws_subnet" "pub-1a" {
  vpc_id                  = aws_vpc.eu-west-2-vpc-1.id
  availability_zone       = "eu-west-2a"
  cidr_block              = cidrsubnet(aws_vpc.eu-west-2-vpc-1.cidr_block, 4, 4)
  map_public_ip_on_launch = true // to determine whether a nw interface created in this subnet is auto-assigned a public IP  

  tags = {
    Name = "tform_pub-vpc1-a"
  }
}


resource "aws_route_table" "publicRouteTable" {
  vpc_id = aws_vpc.eu-west-2-vpc-1.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  /*
  route {
    ipv6_cidr_block        = "::/0"
    egress_only_gateway_id = aws_egress_only_internet_gateway.eigw.id
  }
*/
  tags = {
    Name = "tf-pub"
  }
}

resource "aws_route_table" "privateRouteTable" {
  vpc_id = aws_vpc.eu-west-2-vpc-1.id // this puts the VPC CIDR as local in the route-table, even w/out any subnet association
  /*
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
*/
  tags = {
    Name = "tf-prv"
  }
}


resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.pub-1a.id
  route_table_id = aws_route_table.publicRouteTable.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.prv-1a.id
  route_table_id = aws_route_table.privateRouteTable.id
}


resource "aws_instance" "bastion" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.pub-1a.id
  vpc_security_group_ids = [ aws_security_group.sg.id ]

  tags = {
    Name = "tf_bastion"
  }
}

resource "aws_instance" "host-1" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.prv-1a.id

  tags = {
    Name = "tf_host-1"
  }
}

resource "aws_eip" "persistent_ip" {     // persistent public ip for the bastion server
    instance = aws_instance.bastion.id      
    tags = {
        Name = "tf_eip"
    }
}



locals {
  sgPorts = [22]
  sgCidrBlocks = ["0.0.0.0/0"]
}


resource "aws_security_group" "sg" { 
    name = "bastion-ssh-access"  // Must be unique within a VPC
    vpc_id = aws_vpc.eu-west-2-vpc-1.id // Have to specify this argument when working outside the defaultVPC, otherwise it will go under the defaultVPC

    dynamic "ingress" {
        iterator = port
        for_each = local.sgPorts
        content {
            from_port = port.value
            to_port = port.value
            protocol = "tcp"
            cidr_blocks = local.sgCidrBlocks
        }
    }

# By default, AWS creates an ALLOW ALL egress rule when creating a new Security Group inside of a VPC. 
# When creating a new Security Group inside a VPC, Terraform will remove this default rule, and require you 
# specifically re-create it if you desire that rule. 
# If you want this rule to be in place, you can use this egress block:

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = local.sgCidrBlocks
    }
}
