try:
    import XenAPI
except ImportError as e:
    raise SystemExit('Import Error: %s' % e.message)

import liblogging

__version__ = (0, 0, 1)
__author__ = 'Lorenzo Cocchi <lorenzo.cocchi@softecspa.it>'


class XenServer(object):

    def __init__(self, host, username, password, log_file=None,
                 log_level='INFO'):
        self.session = None
        self.username = username
        self.password = password
        self.host = host
        self.log = liblogging.setup_logging(
            name='XenServer',
            filename=log_file,
            log_level=log_level
        )

    def login(self):
        """If failed login raise XenApi Exception, returns None"""

        try:
            self.session = XenAPI.Session('https://%s' % self.host)
            self.user_session = self.session.xenapi.login_with_password(
                self.username,
                self.password,
            )
        except XenAPI.Failure as e:
            if e.details[0] == 'HOST_IS_SLAVE':
                self.session = XenAPI.Session('https://%s' % e.details[1])
                self.user_session = self.session.xenapi.login_with_password(
                    self.username,
                    self.password,
                )
                self.host = e.details[1]
            else:
                self.log.exception('Failed login to %s' % e)
                raise

        self.log.info('Successfully login to %s' % self.host)

    def logout(self):
        """If failed logout raise XenApi Exception, returns None"""

        try:
            self.session.xenapi.session.logout()
        except Exception as e:
            self.log.exception('Logout from %s failed: %s' % (self.host, e))
            raise

        self.log.info('Successfully logout to %s' % self.host)

    def __vm_resident_on_hostname(self, vm_host):
        """Returns dictionary."""
        d = {}

        if vm_host == 'OpaqueRef:NULL':
            d['resident_on_hostname'] = 'NULL'
        else:
            d['resident_on_hostname'] = \
                self.session.xenapi.host.get_name_label(vm_host)

        return d

    def vm_filter(self, vm, power_state=None, is_control_domain=False,
                  is_a_snapshot=False, is_a_template=False):
        """Returns boolean."""

        if (self.session.xenapi.VM.get_is_control_domain(vm) is
                is_control_domain and
            self.session.xenapi.VM.get_is_a_snapshot(vm) is is_a_snapshot and
                self.session.xenapi.VM.get_is_a_template(vm) is is_a_template):

            if power_state is None:
                return True
            elif (self.session.xenapi.VM.get_power_state(vm) == power_state):
                return True

        return False

    def get_sr_from_vdi(self, vdi):
        """Returns dictionary."""

        sr_record = {}
        sr = self.session.xenapi.VDI.get_SR(vdi)
        sr_record = self.session.xenapi.SR.get_record(sr)

        return sr_record

    def get_vdis_from_vbds(self, vbds, vbd_type='Disk'):
        """Returns list of dictionary."""

        vdi_list = []

        for vbd in vbds:
            vbd_record = self.session.xenapi.VBD.get_record(vbd)

            try:
                if vbd_record['type'] == vbd_type:
                    vdi = vbd_record['VDI']
                    vdi_record = self.session.xenapi.VDI.get_record(vdi)
                    vdi_record['SR'] = self.get_sr_from_vdi(vdi)
                    vdi_list.append(vdi_record)
            except Exception as e:
                self.log.exception('%s' % e)
                raise

        return vdi_list

    def get_vm_list(self, power_state=None, is_control_domain=False,
                    is_a_snapshot=False, is_a_template=False):
        """Returns list of dictionary."""

        vm_list = []

        try:
            vms = self.session.xenapi.VM.get_all()

            for vm in vms:
                if self.vm_filter(vm, power_state=power_state,
                                  is_a_template=is_a_template) is True:
                    vm_record = self.session.xenapi.VM.get_record(vm)
                    roh = self.__vm_resident_on_hostname(
                            vm_record['resident_on']
                    )
                    vm_record.update(roh)
                    vdis = self.get_vdis_from_vbds(vm_record['VBDs'])
                    vm_record['VDIs'] = vdis
                    vm_list.append(vm_record)

            return vm_list
        except Exception as e:
            self.log.exception('Error retreiving VM list by host: %s' % e)
            raise

    def get_simple_vm_list(self, power_state=None, is_a_template=False):
        """Returns dictionary."""

        vm_list = {}

        try:
            vms = self.session.xenapi.VM.get_all()
            for vm in vms:
                if self.vm_filter(vm, power_state) is True:
                    vm_name = self.session.xenapi.VM.get_name_label(vm)
                    dom0 = self.session.xenapi.VM.get_resident_on(vm)

                    if dom0 == 'OpaqueRef:NULL':
                        dom0_name = 'NULL'
                    else:
                        dom0_name = \
                            self.session.xenapi.host.get_name_label(dom0)

                    if dom0_name not in vm_list:
                        vm_list[dom0_name] = []

                    vm_list[dom0_name].append(vm_name)

            return vm_list
        except Exception as e:
            self.log.exception('Error retreiving VM list by host: %s' % e)
            raise

    def get_simple_sr_list(self):
        """Returns list."""

        sr_list = []

        try:
            srs = self.session.xenapi.SR.get_all()
            for sr in srs:
                if self.session.xenapi.SR.get_shared(sr):
                    sr_list.append(self.session.xenapi.SR.get_name_label(sr))
            return sr_list
        except Exception as e:
            self.log.exception('Error retreiving SR list: %s' % str(e))
            raise

    def get_pool_master(self):
        return self.host

    def get_pool_name(self):
        try:
            for node in self.session.xenapi.pool.get_all():
                master = self.session.xenapi.pool.get_master(node)
                if self.session.xenapi.host.get_address(master) == self.host:
                    return self.session.xenapi.pool.get_name_label(node)
                    break

            return None
        except Exception as e:
            self.log.exception('Error retreiving Pool name: %s' % str(e))
            raise

    # def __del__(self):
    #    self.logout()
