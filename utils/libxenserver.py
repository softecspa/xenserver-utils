#!/usr/bin/python

from __future__ import print_function

try:
    import XenAPI
except ImportError as e:
    raise SystemExit('Import Error: %s' % e.message)

import logging
import logging.handlers
import sys

__version__ = (0, 0, 1)
__author__ = 'Lorenzo Cocchi <lorenzo.cocchi@softecspa.it>'


class XenServer(object):

    def __init__(self, host, username, password, log_file=None,
                 log_level='INFO'):
        self.session = None
        self.username = username
        self.password = password
        self.host = host
        self.log = self.__logging(
            name='XenServer',
            filename=log_file,
            log_level=log_level
        )

    def login(self):
        """Returns boolean."""

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
                return False

        self.log.info('Successfully login to %s' % self.host)
        return True

    def logout(self):
        """Returns boolean."""

        try:
            self.session.xenapi.session.logout()
        except Exception as e:
            self.log.exception('Logout from %s failed: %s' % (self.host, e))
            return False

        self.log.info('Logout from %s: successfully' % self.host)
        return True

    def __vm_custom_fields(self, vm_record):
        """Returns dictionary."""

        f_commessa = 'XenCenter.CustomFields.commessa'
        vm_host = vm_record['resident_on']

        if vm_host == 'OpaqueRef:NULL':
            vm_record['resident_on_hostname'] = 'NULL'
        else:
            vm_record['resident_on_hostname'] = \
                self.session.xenapi.host.get_name_label(vm_host)

        if f_commessa in vm_record['other_config']:
            vm_record['commessa'] = \
                vm_record['other_config'][f_commessa]
        else:
            vm_record['commessa'] = 'NULL'

        return vm_record

    def vm_filter(self, vm, power_state=None):
        """Returns boolean."""
        if (self.session.xenapi.VM.get_is_control_domain(vm) is False and
                self.session.xenapi.VM.get_is_a_template(vm) is False and
                self.session.xenapi.VM.get_is_a_snapshot(vm) is False):

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

    def get_vm_list(self, power_state=None):
        """Returns list of dictionary."""

        vm_list = []

        try:
            vms = self.session.xenapi.VM.get_all()

            for vm in vms:
                if self.vm_filter(vm, power_state) is True:
                    vm_record = self.session.xenapi.VM.get_record(vm)
                    vm_record = self.__vm_custom_fields(vm_record)
                    vdis = self.get_vdis_from_vbds(vm_record['VBDs'])
                    vm_record['VDIs'] = vdis
                    vm_list.append(vm_record)

            return vm_list
        except Exception as e:
            self.log.exception('Error retreiving VM list by host: %s' % e)
            raise

    def get_simple_vm_list(self, power_state=None):
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

    def __logging(self, name=None, filename=None, filemode='a',
                  log_level='INFO', fmt=None, datefmt=None, rotate=False,
                  rotate_max_bytes=1024, rotate_backup_count=10):

        logger = logging.getLogger(name)

        if fmt is None:
            fmt = \
                '%(asctime)s [%(levelname)s] %(name)s.%(module)s: %(message)s'

        formatter = logging.Formatter(fmt, datefmt)

        if filename is True or filename is False:
            raise ValueError('filename should not be boolean')

        if filename is None:
            # sys.stderr
            handler = logging.StreamHandler()
        elif filename == '-':
            handler = logging.StreamHandler(sys.stdout)
        elif filename and filename != '-':
            if rotate is False:
                handler = logging.FileHandler(filename, mode=filemode)
            else:
                handler = logging.handlers.RotatingFileHandler(
                    filename,
                    mode=filemode,
                    maxBytes=rotate_max_bytes,
                    backupCount=rotate_backup_count
                )
        else:
            handler = logging.NullHandler()

        handler.setFormatter(formatter)
        logger.addHandler(handler)
        logger.setLevel(getattr(logging, log_level))

        return logger

    # def __del__(self):
    #    self.logout()


def main():
    if len(sys.argv) < 3:
        usage = ('Usage: %s hostname username password' % sys.argv[0])
        usage_ex = ('Ex.: %s 192.168.33.52 r00t foobar' % sys.argv[0])
        raise SystemExit('%s\n%s' % (usage, usage_ex))

    host = sys.argv[1]
    username = sys.argv[2]
    password = sys.argv[3]

    vm_fields = (
        'name_label',
        'uuid',
        'power_state',
        'resident_on_hostname',
        'VCPUs_max',
        'memory_static_max',
        'commessa',
    )

    disk_fields = (
        'uuid',
        'name_description',
        'name_label',
        'virtual_size',
        'physical_utilisation',
    )

    sr_fields = (
        'name_label',
        'physical_size',
        'physical_utilisation'
    )

    xen = XenServer(host, username, password)

    if xen.login() is True:
        try:
            print('%-30s: %s' % ('Pool Master', xen.get_pool_master()))
            print('%-30s: %s' % ('Pool Name', xen.get_pool_name()))
            print()
            for vm in xen.get_vm_list():
                for f in vm_fields:
                    print('%-30s: %s' % ('vm_' + f.lower(), vm[f]))

                vdis = vm['VDIs']
                print('%-30s: %s' % ('vm_vdis', len(vdis)))
                print(end='\n')

                for vdi in vdis:
                    for f in disk_fields:
                        print('%-30s: %s' % ('disk_' + f.lower(), vdi[f]))

                    sr = vdi['SR']
                    for f in sr_fields:
                        print('%-30s: %s' % ('sr_' + f.lower(), sr[f]))

                    print(end='\n')

                print(end='\n')
        except Exception as e:
            raise SystemExit('%s' % e)
        finally:
            xen.logout()

if __name__ == '__main__':
    main()
