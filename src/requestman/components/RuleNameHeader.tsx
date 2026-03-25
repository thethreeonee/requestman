import React from 'react';
import { Button, Input, Space, Typography } from '../primitives';
import { EditOutlined } from '../icons';
import { Binary } from '@/components/animate-ui/icons/binary';
import { Blend } from '@/components/animate-ui/icons/blend';
import { CircleX } from '@/components/animate-ui/icons/circle-x';
import { CircuitBoard } from '@/components/animate-ui/icons/circuit-board';
import { Gauge } from '@/components/animate-ui/icons/gauge';
import { LayoutDashboard } from '@/components/animate-ui/icons/layout-dashboard';
import { Orbit } from '@/components/animate-ui/icons/orbit';
import { Route } from '@/components/animate-ui/icons/route';
import { User } from '@/components/animate-ui/icons/user';
import { RULE_TYPE_LABEL_MAP } from '../constants';
import type { RedirectRule } from '../types';

type Props = {
  rule: RedirectRule;
  editRuleName: boolean;
  setEditRuleName: React.Dispatch<React.SetStateAction<boolean>>;
  setWorkingRule: React.Dispatch<React.SetStateAction<RedirectRule | null>>;
};

const RULE_TYPE_ICON_MAP: Record<RedirectRule['type'], React.ReactNode> = {
  redirect_request: <Route size={14} />,
  rewrite_string: <CircuitBoard size={14} />,
  query_params: <Orbit size={14} />,
  modify_request_body: <LayoutDashboard size={14} />,
  modify_response_body: <Binary size={14} />,
  modify_headers: <Blend size={14} />,
  user_agent: <User size={14} />,
  cancel_request: <CircleX size={14} />,
  request_delay: <Gauge size={14} />,
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
