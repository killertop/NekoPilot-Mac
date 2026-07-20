import { ListRow, ToggleListRow } from "../common/list-row";

interface SettingItemProps {
  icon: React.ReactNode;
  title: string;
  subTitle?: string;
  badge?: string | React.ReactNode;
  onPress?: () => void;
  disabled?: boolean;
}

interface ToggleSettingProps {
  icon: React.ReactNode;
  title: string;
  subTitle?: string;
  isEnabled: boolean;
  onToggle: () => void;
  disabled?: boolean;
}

// iOS Settings row. 52px minimum height (Apple HIG minimum touch target).
// Icon column is a fixed 28px tile to align multi-row cells vertically.
// Hover/active states use Apple tinted-label colours, not Tailwind greys.
export function SettingItem({
  icon,
  title,
  subTitle,
  badge,
  onPress,
  disabled = false,
}: SettingItemProps) {
  return (
    <ListRow
      leading={icon}
      title={title}
      subtitle={subTitle}
      trailing={badge}
      onPress={onPress}
      disabled={disabled}
      showChevron={Boolean(onPress)}
    />
  );
}

export function ToggleSetting({
  icon,
  title,
  subTitle,
  isEnabled,
  onToggle,
  disabled = false,
}: ToggleSettingProps) {
  return (
    <ToggleListRow
      leading={icon}
      title={title}
      subtitle={subTitle}
      checked={isEnabled}
      onChange={onToggle}
      disabled={disabled}
      ariaLabel={title}
    />
  );
}
