declare namespace chrome {
  namespace declarativeNetRequest {
    type ResourceType = any;
    type RequestMethod = any;
    type HeaderInfo = any;
    type Rule = any;
    type RuleAction = any;
    type RuleCondition = any;

    function updateDynamicRules(options: { removeRuleIds?: number[]; addRules?: Rule[] }): Promise<void>;
  }

  namespace storage {
    type StorageChange = { oldValue?: any; newValue?: any };
    const onChanged: {
      addListener(callback: (changes: Record<string, StorageChange>, areaName: string) => void): void;
      removeListener(callback: (changes: Record<string, StorageChange>, areaName: string) => void): void;
    };
    namespace local {
      function get(keys: string[] | string): Promise<Record<string, any>>;
      function get(keys: string[] | string, callback: (items: Record<string, any>) => void): void;
      function set(items: Record<string, any>): Promise<void>;
      function set(items: Record<string, any>, callback: () => void): void;
    }
  }

  namespace runtime {
    const lastError: { message?: string } | undefined;
    const onStartup: { addListener(callback: () => void): void };
    const onInstalled: { addListener(callback: () => void): void };
    const onMessage: { addListener(callback: (message: any, sender: any, sendResponse: (response?: any) => void) => void): void };

    function sendMessage(message: any): void;
    function sendMessage(message: any, callback: (response?: any) => void): void;
  }

  namespace devtools {
    namespace panels {
      function create(title: string, iconPath: string, pagePath: string, callback?: (panel: any) => void): void;
    }
  }
}

declare const chrome: typeof chrome;
