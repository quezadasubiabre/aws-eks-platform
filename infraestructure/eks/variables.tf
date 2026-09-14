variable "admin_iam_user" {
  description = "IAM user name to grant EKS cluster admin access via an access entry"
  type        = string
}

variable "gpu_desired_size" {
  description = "Desired size of the GPU node group. Keep at 0 by default; scale to 1 only while actively testing vLLM, since Spot g5.xlarge still runs ~$0.30-0.45/hr in eu-west-1."
  type        = number
  default     = 0
}
