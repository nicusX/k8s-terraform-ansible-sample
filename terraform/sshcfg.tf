####################
## Generate ssh.cfg
####################

# Generate ../ssh.cfg
data "template_file" "ssh_cfg" {
    template = "${file("${path.module}/template/ssh.cfg")}"
    depends_on = ["aws_instance.etcd", "aws_instance.controller", "aws_instance.worker"]
    vars {
      user = "${var.default_instance_user}"

      etcd0_ip = "${aws_instance.etcd.0.public_ip}"
      etcd1_ip = "${aws_instance.etcd.1.public_ip}"
      etcd2_ip = "${aws_instance.etcd.2.public_ip}"
      controller0_ip = "${aws_instance.controller.0.public_ip}"
      controller1_ip = "${aws_instance.controller.1.public_ip}"
      controller2_ip = "${aws_instance.controller.2.public_ip}"
      worker0_ip = "${aws_instance.worker.0.public_ip}"
      worker1_ip = "${aws_instance.worker.1.public_ip}"
      worker2_ip = "${aws_instance.worker.2.public_ip}"
    }
}
resource "null_resource" "ssh_cfg" {
  triggers {
    template_rendered = "${ data.template_file.ssh_cfg.rendered }"
  }
  provisioner "local-exec" {
    command = "echo '${ data.template_file.ssh_cfg.rendered }' > ../ssh.cfg"
  }
}
