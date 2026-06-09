//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct JunchatSupportScreen: View {
    var body: some View {
        Form {
            Section("关于君聊") {
                SupportInfoRow(title: "君聊",
                               description: "君聊是公司内部沟通工具，默认连接公司自有服务器。")
                SupportInfoRow(title: "服务器",
                               description: "junchat.yyzs120.cn")
            }
            
            Section("联系管理员") {
                SupportInfoRow(title: "账号由管理员创建",
                               description: "如需新增账号、重置密码或调整权限，请联系公司系统管理员。")
            }
            
            Section("数据与隐私") {
                SupportInfoRow(title: "消息安全",
                               description: "私聊和群聊沿用 Matrix 加密与设备验证能力。更换设备后可能需要完成密钥确认。")
                SupportInfoRow(title: "通讯录数据",
                               description: "通讯录仅展示本公司服务器内的可见账号，不会搜索外部 Matrix 网络。")
            }
            
            Section("通讯录隐私") {
                SupportInfoRow(title: "不显示在他人通讯录",
                               description: "开启后，其他人查看公司通讯录时不会看到你的账号；已经存在的聊天不会被删除。")
            }
        }
        .compoundList()
        .navigationTitle("君聊支持中心")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SupportInfoRow: View {
    let title: String
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.compound.bodyMDSemibold)
                .foregroundColor(.compound.textPrimary)
            Text(description)
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}
