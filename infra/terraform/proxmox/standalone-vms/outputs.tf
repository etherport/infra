output "standalone_vms" {
  value = {
    for name, vm in proxmox_virtual_environment_vm.standalone :
    name => {
      name = vm.name
      ip   = local.standalone_vms[name].ip
    }
  }
}
