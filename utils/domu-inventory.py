#!/usr/bin/env python

try:
    import XenAPI
except ImportError as e:
    raise SystemExit('Import Error: %s' % e)

import sys
import traceback


__version__ = (0, 0, 1)
__author__ = 'Lorenzo Cocchi'


def humanize_bytes(bytes):
    """
    Keywords arguments:
        bytes -- size in bytes

    Returns: tuple
    """
    if bytes == 1:
        return '%s %s' % (float(1), 'B')

    suffixes_table = [
        ('B', 0), ('kiB', 0), ('MiB', 1), ('GiB', 2), ('TiB', 2),
        ('PiB', 2),
    ]

    num = float(bytes)
    for suffix, precision in suffixes_table:
        if num < 1024.0:
            break
        num /= 1024.0

    if precision == 0:
        formatted_size = '%d' % num
    else:
        formatted_size = str(round(num, ndigits=precision))

    return float(formatted_size), suffix


def get_all_vm(session):
    """
    Keywords arguments:
        session -- xenapi session object

    Returns: dict
    """

    return session.xenapi.VM.get_all()


def vm_filter(session, vm, power_state=None):
    if (session.xenapi.VM.get_is_control_domain(vm) is False and
            session.xenapi.VM.get_is_a_template(vm) is False and
            session.xenapi.VM.get_is_a_snapshot(vm) is False):

        if (power_state is not None and
                session.xenapi.VM.get_power_state(vm) == power_state):
            return vm

        if power_state is None:
            return vm


def get_vdi_from_vbd(session, vdb, vbd_type='Disk'):
    vdi_record = {}
    vbd_record = session.xenapi.VBD.get_record(vdb)

    if vbd_record['type'] == vbd_type:
        vdi = vbd_record['VDI']
        vdi_sr = session.xenapi.VDI.get_SR(vdi)

        vdi_vm = session.xenapi.VBD.get_VM(vbd)
        vdi = vbd_record['VDI']
        vdi_sr = session.xenapi.VDI.get_SR(vdi)
        vdi_record = session.xenapi.VDI.get_record(vdi)

        vdi_record['sr_vdi'] = session.xenapi.VDI.get_SR(vdi)
        vdi_record['name'] = session.xenapi.VDI.get_name_label(vdi)
        vdi_record['human_size'] = \
            humanize_bytes(vdi_record['virtual_size'])
        vdi_record['sr_uuid'] = session.xenapi.SR.get_uuid(vdi_sr)
        vdi_record['sr_name'] = session.xenapi.SR.get_name_label(vdi_sr)
        vdi_record['sr_type'] = session.xenapi.SR.get_type(vdi_sr)
        vdi_record['vm_uuid'] = session.xenapi.VM.get_uuid(vdi_vm)
        vdi_record['vm_name'] = session.xenapi.VM.get_name_label(vdi_vm)
        vdi_record['vm_dev'] = session.xenapi.VBD.get_userdevice(vbd)

    return vdi_record


if __name__ == '__main__':
    if len(sys.argv) < 3:
        script_name = sys.argv[0]
        usage = ('Usage: %s hostname username password')
        usage_ex = ('Ex.: %s 192.168.33.52 r00t foobar')
        print >>sys.stderr, (usage % script_name)
        print >>sys.stderr, (usage_ex % script_name)
        sys.exit(1)

    host = sys.argv[1]
    username = sys.argv[2]
    password = sys.argv[3]

    try:
        session = XenAPI.Session('https://' + host)
        session.xenapi.login_with_password(username, password)
    except XenAPI.Failure as e:
        if e.details[0] == 'HOST_IS_SLAVE':
            session = XenAPI.Session('https://%s' % e.details[1])
            session.xenapi.login_with_password(username, password)
        else:
            raise SystemExit('XenAPI login Error : %s' % e.details[0])

    try:
        vms = get_all_vm(session)

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
            'virtual_size',
            'sr_name',
            'sr_type',
        )

        f_commessa = 'XenCenter.CustomFields.commessa'

        for vm in vms:
            if vm_filter(session, vm) is not None:
                vm_record = session.xenapi.VM.get_record(vm)

                vmhostref = vm_record['resident_on']
                if vmhostref == 'OpaqueRef:NULL':
                    vm_record['resident_on_hostname'] = 'NULL'
                else:
                    vm_record['resident_on_hostname'] = vmhostref = \
                        session.xenapi.host.get_name_label(vmhostref)

                if f_commessa in vm_record['other_config']:
                    vm_record['commessa'] = \
                        vm_record['other_config'][f_commessa]
                else:
                    vm_record['commessa'] = 'NULL'

                for f in vm_fields:
                    print('%-30s: %s' % ('vm_' + f.lower(), vm_record[f]))

                for vbd in vm_record['VBDs']:
                    vdi = get_vdi_from_vbd(session, vbd)
                    if vdi:
                        for f in disk_fields:
                            print('%-30s: %s' % ('disk_' + f.lower(), vdi[f]))

                print('\n')
    except Exception as e:
        traceback.print_exc(limit=1, file=sys.stderr)
        raise SystemExit()
    finally:
        try:
            session.logut()
        except:
            pass
