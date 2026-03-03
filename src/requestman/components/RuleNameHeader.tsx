import React from 'react';
import { Button, Input, Space, Typography } from 'antd';
import {
  ApiOutlined,
  ClockCircleOutlined,
  CodeOutlined,
  EditOutlined,
  FileDoneOutlined,
  FileSearchOutlined,
  InsertRowAboveOutlined,
  RetweetOutlined,
  StopOutlined,
  UserOutlined,
} from '@ant-design/icons';
import { RULE_TYPE_LABEL_MAP } from '../constants';
import type { RedirectRule } from '../types';

type Props = {
  rule: RedirectRule;
  editRuleName: boolean;
  setEditRuleName: React.Dispatch<React.SetStateAction<boolean>>;
  setWorkingRule: React.Dispatch<React.SetStateAction<RedirectRule | null>>;
};

const RULE_TYPE_ICON_MAP: Record<RedirectRule['type'], React.ReactNode> = {
  redirect_request: <RetweetOutlined />,
  rewrite_string: <CodeOutlined />,
  query_params: <InsertRowAboveOutlined />,
  modify_request_body: <FileSearchOutlined />,
  modify_response_body: <FileDoneOutlined />,
  modify_headers: <ApiOutlined />,
  user_agent: <UserOutlined />,
  cancel_request: <StopOutlined />,
  request_delay: <ClockCircleOutlined />,
};

export default function RuleNameHeader({ rule, editRuleName, setEditRuleName, setWorkingRule }: Props) {
  return (
    <Space align="start" style={{ marginBottom: 16 }}>
      <div>
        {editRuleName ? (
          <Input
            value={rule.name}
            onChange={(e) => setWorkingRule({ ...rule, name: e.target.value })}
            onBlur={() => setEditRuleName(false)}
            onPressEnter={() => setEditRuleName(false)}
          />
        ) : (
          <Typography.Title level={4} style={{ margin: 0 }}>{rule.name}</Typography.Title>
        )}
        <Space size={6} align="center" style={{ marginTop: 8 }}>
          <Typography.Text type="secondary" style={{ fontSize: 14 }}>
            {RULE_TYPE_ICON_MAP[rule.type]}
          </Typography.Text>
          <Typography.Text type="secondary" style={{ fontSize: 14 }}>
            {RULE_TYPE_LABEL_MAP[rule.type]}
          </Typography.Text>
        </Space>
      </div>
      <Button type="text" icon={<EditOutlined />} onClick={() => setEditRuleName(true)} />
    </Space>
  );
}
