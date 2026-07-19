import { AnimatePresence, motion } from "framer-motion";
import {
    ReactNode,
    useCallback,
    useEffect,
    useLayoutEffect,
    useRef,
    useState,
} from "react";
import { Check, ChevronExpand } from "react-bootstrap-icons";
import { Portal } from "../common/portal";

export type AppleSelectOption<T> = {
    value: T;
    key: string;
    disabled?: boolean;
    raw?: unknown;
};

type TriggerRenderArgs<T> = {
    selected: AppleSelectOption<T> | undefined;
    isOpen: boolean;
};

type OptionRenderArgs<T> = {
    option: AppleSelectOption<T>;
    isSelected: boolean;
};

type AppleSelectMenuProps<T> = {
    value: T | null | undefined;
    options: AppleSelectOption<T>[];
    onChange: (value: T) => void;
    renderTrigger: (args: TriggerRenderArgs<T>) => ReactNode;
    renderOption: (args: OptionRenderArgs<T>) => ReactNode;
    disabled?: boolean;
    emptyLabel?: ReactNode;
    menuMaxHeight?: number;
    keyEquals?: (a: T, b: T) => boolean;
    className?: string;
};

type MenuPosition = {
    left: number;
    width: number;
    top?: number;
    bottom?: number;
};

// Apple-style custom popup menu.
// Soft fill, no borders, backdrop blur on the popover surface, spring-like
// entrance sized to the trigger width. Auto-flips above the trigger when
// the viewport lacks room below.
export function AppleSelectMenu<T>(props: AppleSelectMenuProps<T>) {
    const {
        value,
        options,
        onChange,
        renderTrigger,
        renderOption,
        disabled,
        emptyLabel,
        menuMaxHeight = 240,
        keyEquals,
        className,
    } = props;

    const [isOpen, setIsOpen] = useState(false);
    const [placement, setPlacement] = useState<"up" | "down">("down");
    const [menuPosition, setMenuPosition] = useState<MenuPosition | null>(null);
    const wrapperRef = useRef<HTMLDivElement>(null);
    const triggerRef = useRef<HTMLButtonElement>(null);
    const menuRef = useRef<HTMLDivElement>(null);

    const selected = options.find((opt) =>
        keyEquals
            ? value != null && keyEquals(opt.value, value)
            : opt.value === value,
    );

    useEffect(() => {
        if (!isOpen) return;
        const onDocClick = (event: MouseEvent) => {
            const target = event.target as Node;
            if (!wrapperRef.current?.contains(target) && !menuRef.current?.contains(target)) {
                setIsOpen(false);
            }
        };
        const onEsc = (event: KeyboardEvent) => {
            if (event.key === "Escape") setIsOpen(false);
        };
        document.addEventListener("mousedown", onDocClick);
        document.addEventListener("keydown", onEsc);
        return () => {
            document.removeEventListener("mousedown", onDocClick);
            document.removeEventListener("keydown", onEsc);
        };
    }, [isOpen]);

    const updateMenuPosition = useCallback(() => {
        if (!isOpen) return;
        const rect = triggerRef.current?.getBoundingClientRect();
        if (!rect) return;
        const spaceBelow = window.innerHeight - rect.bottom;
        const spaceAbove = rect.top;
        const needed = menuMaxHeight + 16;
        const nextPlacement =
            spaceBelow < needed && spaceAbove > spaceBelow ? "up" : "down";
        const nextPosition: MenuPosition = nextPlacement === "up"
            ? {
                left: rect.left,
                width: rect.width,
                bottom: window.innerHeight - rect.top + 8,
            }
            : {
                left: rect.left,
                width: rect.width,
                top: rect.bottom + 8,
            };

        setPlacement((previous) => previous === nextPlacement ? previous : nextPlacement);
        setMenuPosition((previous) => {
            if (
                previous
                && previous.left === nextPosition.left
                && previous.width === nextPosition.width
                && previous.top === nextPosition.top
                && previous.bottom === nextPosition.bottom
            ) {
                return previous;
            }
            return nextPosition;
        });
    }, [isOpen, menuMaxHeight]);

    useLayoutEffect(() => {
        if (!isOpen) {
            setMenuPosition(null);
            return;
        }
        updateMenuPosition();
    }, [isOpen, updateMenuPosition]);

    useEffect(() => {
        if (!isOpen) return;

        window.addEventListener("resize", updateMenuPosition);
        window.addEventListener("scroll", updateMenuPosition, true);
        return () => {
            window.removeEventListener("resize", updateMenuPosition);
            window.removeEventListener("scroll", updateMenuPosition, true);
        };
    }, [isOpen, updateMenuPosition]);

    const toggle = () => {
        if (disabled) return;
        setIsOpen((open) => !open);
    };

    return (
        <div ref={wrapperRef} className={`relative w-full ${className ?? ""}`}>
            <button
                ref={triggerRef}
                type="button"
                disabled={disabled}
                onClick={toggle}
                aria-haspopup="listbox"
                aria-expanded={isOpen}
                style={{ background: 'var(--onebox-card)', boxShadow: 'var(--onebox-shadow-card)' }}
                className={`
                    group w-full text-left rounded-2xl
                    px-3.5 py-2.5
                    transition-all duration-150 ease-out
                    active:scale-[0.995]
                    focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500/30
                    disabled:opacity-60 disabled:cursor-not-allowed
                    disabled:active:scale-100
                `}
            >
                <div className="flex items-center gap-2">
                    <div className="flex-1 min-w-0">
                        {renderTrigger({ selected, isOpen })}
                    </div>
                    <ChevronExpand
                        className="size-3 shrink-0 transition-transform duration-200"
                        style={{
                            color: isOpen
                                ? 'var(--onebox-blue)'
                                : 'var(--onebox-label-tertiary)',
                        }}
                    />
                </div>
            </button>

            <Portal>
                <AnimatePresence>
                    {isOpen && menuPosition && (
                        <motion.div
                            ref={menuRef}
                            key="apple-select-menu"
                            initial={{
                                opacity: 0,
                                scale: 0.96,
                                y: placement === "up" ? 6 : -6,
                            }}
                            animate={{ opacity: 1, scale: 1, y: 0 }}
                            exit={{
                                opacity: 0,
                                scale: 0.97,
                                y: placement === "up" ? 4 : -4,
                            }}
                            transition={{
                                duration: 0.16,
                                ease: [0.32, 0.72, 0, 1],
                            }}
                            style={{
                                ...menuPosition,
                                transformOrigin:
                                    placement === "up" ? "50% 100%" : "50% 0%",
                            }}
                            className="fixed z-[70]"
                            role="listbox"
                        >
                        <div
                            className="overflow-hidden rounded-2xl backdrop-blur-2xl backdrop-saturate-150"
                            style={{
                                background: 'var(--onebox-menu-bg)',
                                boxShadow:
                                    '0 16px 48px rgba(15, 23, 42, 0.16), 0 4px 12px rgba(15, 23, 42, 0.08)',
                            }}
                        >
                            <div
                                className="onebox-scrollbar-hidden overflow-y-auto p-1.5"
                                style={{ maxHeight: menuMaxHeight }}
                            >
                                {options.length === 0 ? (
                                    <div
                                        className="px-3 py-3 text-sm text-center"
                                        style={{ color: 'var(--onebox-label-tertiary)' }}
                                    >
                                        {emptyLabel ?? "—"}
                                    </div>
                                ) : (
                                    options.map((option) => {
                                        const isSelected = option === selected;
                                        return (
                                            <button
                                                key={option.key}
                                                type="button"
                                                disabled={option.disabled}
                                                onClick={() => {
                                                    if (option.disabled) return;
                                                    onChange(option.value);
                                                    setIsOpen(false);
                                                }}
                                                className={`
                                                    onebox-menu-option
                                                    w-full text-left
                                                    px-3 py-2 rounded-xl
                                                    flex items-center gap-2
                                                    transition-colors duration-100
                                                    focus:outline-none
                                                    ${isSelected ? "bg-blue-500/10" : ""}
                                                    ${option.disabled ? "opacity-40 cursor-not-allowed" : ""}
                                                `}
                                            >
                                                <div className="flex-1 min-w-0">
                                                    {renderOption({
                                                        option,
                                                        isSelected,
                                                    })}
                                                </div>
                                                <Check
                                                    className={`
                                                        size-4 shrink-0 text-blue-500
                                                        transition-opacity duration-150
                                                        ${isSelected ? "opacity-100" : "opacity-0"}
                                                    `}
                                                />
                                            </button>
                                        );
                                    })
                                )}
                            </div>
                        </div>
                        </motion.div>
                    )}
                </AnimatePresence>
            </Portal>
        </div>
    );
}

// Rendered when a selector has nothing actionable (loading, empty, or
// "not running"). Keeps vertical rhythm identical to the active trigger
// so the layout doesn't jump between states.
export function AppleSelectPlaceholder({
    children,
    tone = "muted",
}: {
    children: ReactNode;
    tone?: "muted" | "loading";
}) {
    return (
        <div
            className={`
                w-full rounded-2xl px-3.5 py-2.5
                flex items-center gap-2
                ${tone === "loading" ? "" : "opacity-70"}
            `}
            style={{
                background: 'var(--onebox-card)',
                boxShadow: 'var(--onebox-shadow-card)',
            }}
        >
            <div
                className="flex-1 min-w-0 text-sm"
                style={{ color: 'var(--onebox-label-tertiary)' }}
            >
                {children}
            </div>
        </div>
    );
}
