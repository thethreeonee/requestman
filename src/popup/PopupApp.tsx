import React, { useEffect, useState } from 'react';
import { Settings } from 'lucide-react';
import { motion } from 'motion/react';
import { t } from '../requestman/i18n';
import { HIT_TOAST_ENABLED_KEY, REDIRECT_ENABLED_KEY, RULE_TYPE_LABEL_MAP } from '../requestman/constants';
import { Switch } from '@/components/animate-ui/components/radix/switch';
import { AnimateIcon } from '@/components/animate-ui/icons/icon';
import { EllipsisVertical } from '@/components/animate-ui/icons/ellipsis-vertical';
import { MessageSquareShare } from '@/components/animate-ui/icons/message-square-share';
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
} from '@/components/animate-ui/components/radix/dropdown-menu';
import { MessageSquareOff } from '@/components/animate-ui/icons/message-square-off';

type HitEntry = { ruleName: string; ruleType: string; url: string; ts: number };

function RuleTypeIcon({ ruleType }: { ruleType: string }) {
  const common = { width: 14, height: 14, fill: 'none', stroke: 'currentColor', strokeWidth: 2, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const };
  switch (ruleType) {
    case 'redirect_request':
      return <svg viewBox="0 0 24 24" {...common}><circle cx="6" cy="19" r="3" /><path d="M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15" /><circle cx="18" cy="5" r="3" /></svg>;
    case 'rewrite_string':
      return <svg viewBox="0 0 24 24" {...common}><rect width="18" height="18" x="3" y="3" rx="2" /><path d="M11 9h4a2 2 0 0 0 2-2V3" /><circle cx="9" cy="9" r="2" /><path d="M7 21v-4a2 2 0 0 1 2-2h4" /><circle cx="15" cy="15" r="2" /></svg>;
    case 'query_params':
      return <svg viewBox="0 0 24 24" {...common}><path d="M20.341 6.484A10 10 0 0 1 10.266 21.85" /><path d="M3.659 17.516A10 10 0 0 1 13.74 2.152" /><circle cx="12" cy="12" r="3" /><circle cx="19" cy="5" r="2" /><circle cx="5" cy="19" r="2" /></svg>;
    case 'modify_request_body':
      return <svg viewBox="0 0 24 24" {...common}><rect width="7" height="9" x="3" y="3" rx="1" /><rect width="7" height="5" x="14" y="3" rx="1" /><rect width="7" height="9" x="14" y="12" rx="1" /><rect width="7" height="5" x="3" y="16" rx="1" /></svg>;
    case 'modify_response_body':
      return <svg viewBox="0 0 24 24" {...common}><rect x="14" y="14" width="4" height="6" rx="2" /><rect x="6" y="4" width="4" height="6" rx="2" /><path d="M6 20h4" /><path d="M14 10h4" /><path d="M6 14h2v6" /><path d="M14 4h2v6" /></svg>;
    case 'modify_headers':
      return <svg viewBox="0 0 24 24" {...common}><circle cx="9" cy="9" r="7" /><circle cx="15" cy="15" r="7" /></svg>;
    case 'user_agent':
      return <svg viewBox="0 0 24 24" {...common}><path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2" /><circle cx="12" cy="7" r="4" /></svg>;
    case 'cancel_request':
      return <svg viewBox="0 0 24 24" {...common}><circle cx="12" cy="12" r="10" /><path d="m15 9-6 6" /><path d="m9 9 6 6" /></svg>;
    case 'request_delay':
      return <svg viewBox="0 0 24 24" {...common}><path d="m12 14 4-4" /><path d="M3.34 19a10 10 0 1 1 17.32 0" /></svg>;
    default:
      return <svg viewBox="0 0 24 24" {...common}><circle cx="12" cy="12" r="10" /><path d="m15 9-6 6" /><path d="m9 9 6 6" /></svg>;
  }
}

function EmptyState() {
  return (
    <div className="flex flex-col items-center justify-center py-10 gap-2 text-muted-foreground">
      <svg viewBox="0 0 24 24" width="28" height="28" fill="none" stroke="currentColor" strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round" className="opacity-30">
        <path d="M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15" />
        <circle cx="6" cy="19" r="3" />
        <circle cx="18" cy="5" r="3" />
      </svg>
      <span className="text-xs">{t('当前页面没有命中规则', 'No rules matched on this page')}</span>
    </div>
  );
}

function HitItem({ hit }: { hit: HitEntry }) {
  const label = RULE_TYPE_LABEL_MAP[hit.ruleType as keyof typeof RULE_TYPE_LABEL_MAP] ?? hit.ruleType;
  return (
    <li className="flex items-center gap-2.5 px-3 py-2.5 rounded-lg bg-accent/50 text-sm">
      <span className="flex-shrink-0 text-muted-foreground">
        <RuleTypeIcon ruleType={hit.ruleType} />
      </span>
      <div className="flex-1 min-w-0">
        <div className="font-medium text-foreground truncate leading-tight">{hit.ruleName || t('（未命名）', '(unnamed)')}</div>
        <div className="text-[11px] text-muted-foreground mt-0.5">{label}</div>
      </div>
    </li>
  );
}

function dedupeHits(hits: HitEntry[]): HitEntry[] {
  const seen = new Set<string>();
  return hits.filter((h) => {
    const key = `${h.ruleType}::${h.ruleName}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export default function PopupApp() {
  const [hits, setHits] = useState<HitEntry[]>([]);
  const [tabId, setTabId] = useState<number | null>(null);
  const [redirectEnabled, setRedirectEnabled] = useState(true);
  const [hitToastEnabled, setHitToastEnabled] = useState(true);

  useEffect(() => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const id = tabs[0]?.id;
      if (id != null) setTabId(id);
    });

    chrome.storage.local.get([REDIRECT_ENABLED_KEY, HIT_TOAST_ENABLED_KEY], (res) => {
      if (chrome.runtime.lastError) return;
      setRedirectEnabled(res?.[REDIRECT_ENABLED_KEY] !== false);
      setHitToastEnabled(res?.[HIT_TOAST_ENABLED_KEY] !== false);
    });
  }, []);

  useEffect(() => {
    if (tabId == null) return;
    function fetchHits() {
      chrome.runtime.sendMessage({ type: 'requestman:get-tab-hits', tabId }, (response) => {
        if (chrome.runtime.lastError) return;
        if (Array.isArray(response?.hits)) setHits(response.hits);
      });
    }
    fetchHits();
    const interval = setInterval(fetchHits, 800);
    return () => clearInterval(interval);
  }, [tabId]);

  function openPanel() {
    chrome.tabs.create({ url: chrome.runtime.getURL('requestman/index.html') });
    window.close();
  }

  function onRedirectEnabledChange(checked: boolean) {
    setRedirectEnabled(checked);
    chrome.storage.local.set({ [REDIRECT_ENABLED_KEY]: checked }, () => {
      void chrome.runtime.lastError;
    });
  }

  function onHitToastEnabledChange(checked: boolean) {
    setHitToastEnabled(checked);
    chrome.storage.local.set({ [HIT_TOAST_ENABLED_KEY]: checked }, () => {
      void chrome.runtime.lastError;
    });
  }

  const displayedHits = dedupeHits(hits);
  const listHint = displayedHits.length > 0
    ? t(`当前页面命中规则（${displayedHits.length}）`, `Matched rules on this page (${displayedHits.length})`)
    : t('当前页面命中规则', 'Matched rules on this page');

  return (
    <div className="w-[360px] flex flex-col bg-background text-foreground">
      {/* Toolbar */}
      <div className="flex items-center justify-between px-3 h-11 border-b border-border flex-shrink-0">
        <div className="flex items-center gap-2">
          <img src="/assets/icon-source.png" alt="Requestman" className="w-5 h-5" />
          <span className="text-[11px] font-bold tracking-widest select-none">REQUESTMAN</span>
        </div>
        <div className="flex items-center gap-2">
          <Switch
            checked={redirectEnabled}
            onCheckedChange={onRedirectEnabledChange}
            className="scale-[0.82] origin-center"
            title={t('插件开关', 'Extension enabled')}
            aria-label={t('插件开关', 'Extension enabled')}
          />
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button
                className="flex items-center justify-center w-7 h-7 rounded-md hover:bg-accent text-muted-foreground hover:text-foreground transition-colors cursor-pointer"
                title={t('更多选项', 'More options')}
              >
                <AnimateIcon animateOnHover asChild>
                  <span className="inline-flex">
                    <EllipsisVertical size={15} animation="pulse" />
                  </span>
                </AnimateIcon>
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem onSelect={() => onHitToastEnabledChange(!hitToastEnabled)}>
                <AnimateIcon animateOnHover asChild>
                  <span className={hitToastEnabled ? 'inline-flex text-muted-foreground' : 'inline-flex text-muted-foreground/40'}>
                    {hitToastEnabled
                      ? <MessageSquareShare size={14} animation="arrow-up" />
                      : <MessageSquareOff size={14} animation="default" />
                    }
                  </span>
                </AnimateIcon>
                {t('页面浮层', 'On-page Toast')}
              </DropdownMenuItem>
              <DropdownMenuItem onSelect={openPanel}>
                <motion.span
                  className="inline-flex text-muted-foreground"
                  whileHover={{ rotate: 90 }}
                  transition={{ type: 'spring', stiffness: 200, damping: 15 }}
                >
                  <Settings size={14} />
                </motion.span>
                {t('打开配置', 'Open settings')}
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>

      {/* Content */}
      <div className="overflow-y-auto max-h-[400px]">
        <div className="px-3 pt-2.5 pb-1 text-[11px] text-muted-foreground">
          {listHint}
        </div>
        {displayedHits.length === 0 ? (
          <EmptyState />
        ) : (
          <ul className="p-2 flex flex-col gap-1">
            {displayedHits.map((hit, i) => (
              <HitItem key={i} hit={hit} />
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
