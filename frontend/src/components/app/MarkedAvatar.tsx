import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";

/**
 * 头像的几档尺寸：`list` 是对话列表（56px），`bubble` 是气泡旁（36px），`call` 是没有立绘时通话层中部（112px），
 * `sm`、`lg` 给记忆页、登录页这类小处，`xs`（20px）、`2xs`（16px）给日历周视图的工作块和行首的生日。
 */
const SIZES = {
  "2xs": "size-4",
  xs: "size-5",
  sm: "size-6",
  bubble: "size-bubble-avatar",
  lg: "size-12",
  list: "size-list-avatar",
  call: "size-28",
} as const;

type Props = {
  name: string;
  src?: string | null;
  size?: keyof typeof SIZES;
};

/**
 * 角色头像：圆形，没有图时显示名字的第一个字。
 * 上一版外面有一圈她颜色的描边；新设计里头像不加描边环、不投影（DESIGN.md「The Flat Rule」），
 * 她的颜色也不出现在规则清单以外的地方（「The Her-Colour-Only-Here Rule」），所以只剩头像本身。
 */
export function MarkedAvatar({ name, src, size = "lg" }: Props) {
  return (
    <Avatar className={SIZES[size]}>
      {src && <AvatarImage src={src} alt={name} />}
      <AvatarFallback>{Array.from(name)[0]}</AvatarFallback>
    </Avatar>
  );
}
