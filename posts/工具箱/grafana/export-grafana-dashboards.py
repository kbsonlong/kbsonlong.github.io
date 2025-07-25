#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Grafana仪表板批量导出工具
支持按文件夹、标签、权限等多种方式导出

使用方法:
    python3 export-grafana-dashboards.py --url http://localhost:3000 --api-key YOUR_API_KEY

环境变量:
    GRAFANA_URL: Grafana服务器地址
    GRAFANA_API_KEY: API密钥
"""

import os
import json
import requests
import argparse
import sys
from datetime import datetime
from pathlib import Path
import re
from urllib.parse import urljoin
import time

class GrafanaExporter:
    def __init__(self, url, api_key, output_dir="./grafana-exports", timeout=30):
        self.url = url.rstrip('/')
        self.api_key = api_key
        self.output_dir = Path(output_dir)
        self.timeout = timeout
        
        # 配置HTTP会话
        self.session = requests.Session()
        self.session.headers.update({
            'Authorization': f'Bearer {api_key}',
            'Content-Type': 'application/json',
            'User-Agent': 'Grafana-Dashboard-Exporter/1.0'
        })
        
        # 创建带时间戳的导出目录
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.export_dir = self.output_dir / f"export_{timestamp}"
        self.export_dir.mkdir(parents=True, exist_ok=True)
        
        print(f"导出目录: {self.export_dir}")
        
    def api_request(self, endpoint, method='GET', data=None, retries=3):
        """发送API请求，支持重试"""
        url = urljoin(self.url, endpoint)
        
        for attempt in range(retries):
            try:
                if method.upper() == 'GET':
                    response = self.session.get(url, timeout=self.timeout)
                elif method.upper() == 'POST':
                    response = self.session.post(url, json=data, timeout=self.timeout)
                else:
                    raise ValueError(f"不支持的HTTP方法: {method}")
                
                response.raise_for_status()
                return response.json()
                
            except requests.exceptions.RequestException as e:
                print(f"API请求失败 (尝试 {attempt + 1}/{retries}): {e}")
                if attempt == retries - 1:
                    return None
                time.sleep(2 ** attempt)  # 指数退避
        
        return None
    
    def safe_filename(self, name):
        """生成安全的文件名"""
        # 替换特殊字符
        safe_name = re.sub(r'[<>:"/\\|?*]', '_', name)
        # 限制长度
        if len(safe_name) > 100:
            safe_name = safe_name[:100]
        return safe_name
    
    def test_connection(self):
        """测试Grafana连接"""
        print("测试Grafana连接...")
        user_info = self.api_request("/api/user")
        
        if user_info:
            print(f"✓ 连接成功! 用户: {user_info.get('login', 'unknown')}")
            print(f"  组织: {user_info.get('orgId', 'unknown')}")
            print(f"  权限: {user_info.get('role', 'unknown')}")
            return True
        else:
            print("✗ 连接失败! 请检查URL和API密钥")
            return False
    
    def get_folders(self):
        """获取所有文件夹"""
        print("获取文件夹列表...")
        folders = self.api_request("/api/folders")
        
        if folders is not None:
            # 添加根文件夹
            folders.insert(0, {
                'id': 0,
                'uid': '',
                'title': 'General',
                'url': '',
                'hasAcl': False,
                'canSave': True,
                'canEdit': True,
                'canAdmin': True,
                'version': 1
            })
            
            # 保存文件夹信息
            folders_file = self.export_dir / "folders.json"
            with open(folders_file, 'w', encoding='utf-8') as f:
                json.dump(folders, f, indent=2, ensure_ascii=False)
            
            print(f"找到 {len(folders)} 个文件夹 (包括根文件夹)")
            return folders
        
        print("获取文件夹列表失败")
        return []
    
    def get_dashboards(self, folder_id=None, tag=None):
        """获取仪表板列表"""
        print("获取仪表板列表...")
        
        # 构建查询参数
        params = ["type=dash-db"]
        if folder_id is not None:
            params.append(f"folderIds={folder_id}")
        if tag:
            params.append(f"tag={tag}")
        
        endpoint = f"/api/search?{'&'.join(params)}"
        dashboards = self.api_request(endpoint)
        
        if dashboards is not None:
            print(f"找到 {len(dashboards)} 个仪表板")
            return dashboards
        
        print("获取仪表板列表失败")
        return []
    
    def get_dashboard_permissions(self, dashboard_uid):
        """获取仪表板权限"""
        return self.api_request(f"/api/dashboards/uid/{dashboard_uid}/permissions")
    
    def export_dashboard(self, dashboard_info, include_permissions=False):
        """导出单个仪表板"""
        uid = dashboard_info['uid']
        title = dashboard_info['title']
        folder_title = dashboard_info.get('folderTitle', 'General')
        
        print(f"导出仪表板: {title} (UID: {uid})")
        
        # 创建文件夹目录
        folder_dir = self.export_dir / self.safe_filename(folder_title)
        folder_dir.mkdir(exist_ok=True)
        
        # 获取仪表板详细信息
        dashboard_data = self.api_request(f"/api/dashboards/uid/{uid}")
        
        if dashboard_data and 'dashboard' in dashboard_data:
            # 生成文件名
            safe_title = self.safe_filename(title)
            filename = folder_dir / f"{safe_title}_{uid}.json"
            
            # 准备导出数据
            export_data = {
                'dashboard': dashboard_data['dashboard'],
                'meta': dashboard_data.get('meta', {}),
                'folderTitle': folder_title,
                'exportTime': datetime.now().isoformat()
            }
            
            # 获取权限信息（如果需要）
            if include_permissions:
                permissions = self.get_dashboard_permissions(uid)
                if permissions:
                    export_data['permissions'] = permissions
            
            # 保存仪表板
            with open(filename, 'w', encoding='utf-8') as f:
                json.dump(export_data, f, indent=2, ensure_ascii=False)
            
            print(f"  ✓ 导出成功: {filename.relative_to(self.export_dir)}")
            return True
        else:
            print(f"  ✗ 导出失败: {title}")
            return False
    
    def export_datasources(self):
        """导出数据源配置"""
        print("导出数据源配置...")
        datasources = self.api_request("/api/datasources")
        
        if datasources:
            datasources_file = self.export_dir / "datasources.json"
            with open(datasources_file, 'w', encoding='utf-8') as f:
                json.dump(datasources, f, indent=2, ensure_ascii=False)
            print(f"✓ 数据源配置已导出: {len(datasources)} 个数据源")
            return True
        
        print("✗ 导出数据源配置失败")
        return False
    
    def export_alerts(self):
        """导出告警规则"""
        print("导出告警规则...")
        alerts = self.api_request("/api/alerts")
        
        if alerts:
            alerts_file = self.export_dir / "alerts.json"
            with open(alerts_file, 'w', encoding='utf-8') as f:
                json.dump(alerts, f, indent=2, ensure_ascii=False)
            print(f"✓ 告警规则已导出: {len(alerts)} 个规则")
            return True
        
        print("✗ 导出告警规则失败")
        return False
    
    def generate_report(self, exported_count, total_count, folders):
        """生成导出报告"""
        report_file = self.export_dir / "export_report.md"
        
        # 统计信息
        folder_dirs = [d for d in self.export_dir.iterdir() if d.is_dir()]
        json_files = list(self.export_dir.rglob("*.json"))
        dashboard_files = [f for f in json_files 
                          if f.name not in ['folders.json', 'datasources.json', 'alerts.json']]
        
        with open(report_file, 'w', encoding='utf-8') as f:
            f.write(f"# Grafana导出报告\n\n")
            f.write(f"**导出时间**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
            f.write(f"**Grafana URL**: {self.url}\n\n")
            f.write(f"**导出目录**: `{self.export_dir}`\n\n")
            
            f.write(f"## 统计信息\n\n")
            f.write(f"| 项目 | 数量 |\n")
            f.write(f"|------|------|\n")
            f.write(f"| 文件夹 | {len(folders)} |\n")
            f.write(f"| 仪表板总数 | {total_count} |\n")
            f.write(f"| 成功导出 | {exported_count} |\n")
            f.write(f"| 失败数量 | {total_count - exported_count} |\n")
            f.write(f"| 成功率 | {exported_count/total_count*100:.1f}% |\n\n")
            
            f.write(f"## 文件夹结构\n\n")
            for folder in folders:
                folder_name = self.safe_filename(folder['title'])
                folder_path = self.export_dir / folder_name
                if folder_path.exists():
                    dashboard_count = len(list(folder_path.glob("*.json")))
                    f.write(f"- **{folder['title']}** ({dashboard_count} 个仪表板)\n")
            
            f.write(f"\n## 导出文件列表\n\n")
            for folder_dir in sorted(folder_dirs):
                folder_name = folder_dir.name
                f.write(f"### {folder_name}\n\n")
                
                dashboard_files_in_folder = sorted(folder_dir.glob("*.json"))
                for file in dashboard_files_in_folder:
                    f.write(f"- `{file.name}`\n")
                f.write(f"\n")
            
            # 添加其他文件
            other_files = [f for f in json_files if f.parent == self.export_dir]
            if other_files:
                f.write(f"### 其他配置文件\n\n")
                for file in sorted(other_files):
                    f.write(f"- `{file.name}`\n")
        
        print(f"✓ 导出报告已生成: {report_file}")
    
    def export_all(self, include_permissions=False, include_datasources=True, include_alerts=True, folder_filter=None, tag_filter=None):
        """导出所有内容"""
        print(f"开始导出Grafana配置...")
        print(f"Grafana URL: {self.url}")
        
        # 测试连接
        if not self.test_connection():
            return False
        
        # 获取文件夹信息
        folders = self.get_folders()
        
        # 导出数据源（如果需要）
        if include_datasources:
            self.export_datasources()
        
        # 导出告警规则（如果需要）
        if include_alerts:
            self.export_alerts()
        
        # 获取仪表板列表
        if folder_filter:
            # 按文件夹过滤
            folder_id = None
            for folder in folders:
                if folder['title'] == folder_filter:
                    folder_id = folder['id']
                    break
            if folder_id is None:
                print(f"未找到文件夹: {folder_filter}")
                return False
            dashboards = self.get_dashboards(folder_id=folder_id, tag=tag_filter)
        else:
            dashboards = self.get_dashboards(tag=tag_filter)
        
        if not dashboards:
            print("未找到任何仪表板")
            return False
        
        # 导出每个仪表板
        exported_count = 0
        for i, dashboard in enumerate(dashboards, 1):
            print(f"[{i}/{len(dashboards)}] ", end="")
            if self.export_dashboard(dashboard, include_permissions):
                exported_count += 1
        
        # 生成报告
        self.generate_report(exported_count, len(dashboards), folders)
        
        print(f"\n{'='*50}")
        print(f"导出完成!")
        print(f"成功导出: {exported_count}/{len(dashboards)} 个仪表板")
        print(f"导出目录: {self.export_dir}")
        print(f"查看报告: {self.export_dir}/export_report.md")
        
        return True

def main():
    parser = argparse.ArgumentParser(
        description='Grafana仪表板批量导出工具',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例用法:
  # 基本导出
  python3 export-grafana-dashboards.py --api-key YOUR_API_KEY
  
  # 指定URL和输出目录
  python3 export-grafana-dashboards.py --url http://grafana.example.com --api-key YOUR_API_KEY --output ./backups
  
  # 只导出特定文件夹
  python3 export-grafana-dashboards.py --api-key YOUR_API_KEY --folder "Production"
  
  # 按标签过滤
  python3 export-grafana-dashboards.py --api-key YOUR_API_KEY --tag "monitoring"
  
  # 包含权限信息
  python3 export-grafana-dashboards.py --api-key YOUR_API_KEY --include-permissions

环境变量:
  GRAFANA_URL: Grafana服务器地址 (默认: http://localhost:3000)
  GRAFANA_API_KEY: API密钥
        """
    )
    
    parser.add_argument('--url', 
                       default=os.getenv('GRAFANA_URL', 'http://localhost:3000'),
                       help='Grafana URL (默认: http://localhost:3000)')
    
    parser.add_argument('--api-key', 
                       default=os.getenv('GRAFANA_API_KEY'),
                       required=not os.getenv('GRAFANA_API_KEY'),
                       help='Grafana API密钥')
    
    parser.add_argument('--output', 
                       default='./grafana-exports',
                       help='导出目录 (默认: ./grafana-exports)')
    
    parser.add_argument('--timeout', 
                       type=int, default=30,
                       help='HTTP请求超时时间 (默认: 30秒)')
    
    parser.add_argument('--folder', 
                       help='只导出指定文件夹的仪表板')
    
    parser.add_argument('--tag', 
                       help='按标签过滤仪表板')
    
    parser.add_argument('--include-permissions', 
                       action='store_true',
                       help='包含仪表板权限信息')
    
    parser.add_argument('--no-datasources', 
                       action='store_true',
                       help='不导出数据源配置')
    
    parser.add_argument('--no-alerts', 
                       action='store_true',
                       help='不导出告警规则')
    
    parser.add_argument('--verbose', '-v', 
                       action='store_true',
                       help='详细输出')
    
    args = parser.parse_args()
    
    # 检查必要参数
    if not args.api_key:
        print("错误: 请提供API密钥 (--api-key 或设置 GRAFANA_API_KEY 环境变量)")
        sys.exit(1)
    
    try:
        # 创建导出器
        exporter = GrafanaExporter(
            url=args.url,
            api_key=args.api_key,
            output_dir=args.output,
            timeout=args.timeout
        )
        
        # 执行导出
        success = exporter.export_all(
            include_permissions=args.include_permissions,
            include_datasources=not args.no_datasources,
            include_alerts=not args.no_alerts,
            folder_filter=args.folder,
            tag_filter=args.tag
        )
        
        sys.exit(0 if success else 1)
        
    except KeyboardInterrupt:
        print("\n用户中断操作")
        sys.exit(1)
    except Exception as e:
        print(f"错误: {e}")
        if args.verbose:
            import traceback
            traceback.print_exc()
        sys.exit(1)

if __name__ == '__main__':
    main()