#--------------------------------------------------------------
# EFS access points
#
# Declarative per-PV access points (DESIGN-0008 Q6). Empty map
# (default) creates zero resources. Each entry's key becomes the
# access point's Name tag; the inner posix_user + root_directory
# objects match the EFS API surface 1:1 (IMPL-0008 Q3 resolution).
#
# posix_user.secondary_gids defaults to [] via the optional()
# default on the variable shape, so the attribute is always
# present in the rendered resource — no dynamic block needed.
#
# root_directory.creation_info is the only optional EFS API field;
# emitted via dynamic block when the caller supplies it.
#--------------------------------------------------------------

resource "aws_efs_access_point" "this" {
  for_each = var.access_points

  file_system_id = aws_efs_file_system.this.id
  tags           = merge(var.tags, { Name = each.key })

  posix_user {
    uid            = each.value.posix_user.uid
    gid            = each.value.posix_user.gid
    secondary_gids = each.value.posix_user.secondary_gids
  }

  root_directory {
    path = each.value.root_directory.path

    dynamic "creation_info" {
      for_each = each.value.root_directory.creation_info != null ? [each.value.root_directory.creation_info] : []

      content {
        owner_uid   = creation_info.value.owner_uid
        owner_gid   = creation_info.value.owner_gid
        permissions = creation_info.value.permissions
      }
    }
  }
}
