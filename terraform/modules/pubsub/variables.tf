variable "project_id" {
  type = string
}

variable "topic_name" {
  type    = string
  default = "order-events"
}

variable "subscription_name" {
  type    = string
  default = "order-events-worker"
}

variable "dlq_topic_name" {
  type    = string
  default = "order-events-dlq"
}

variable "max_delivery_attempts" {
  type    = number
  default = 5
}
