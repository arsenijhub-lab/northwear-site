CREATE TABLE IF NOT EXISTS public.staff_members (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL UNIQUE,
  role text NOT NULL CHECK (role IN ('admin', 'staff')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.staff_invites (
  email text PRIMARY KEY,
  role text NOT NULL CHECK (role IN ('admin', 'staff')),
  invited_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.products (
  id text PRIMARY KEY,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 160),
  category text NOT NULL CHECK (category IN ('hoodie', 'tee', 'pants', 'jacket', 'other')),
  tags text[] NOT NULL DEFAULT '{}',
  label text NOT NULL DEFAULT '',
  price numeric(12, 2) CHECK (price IS NULL OR price >= 0),
  sizes text[] NOT NULL DEFAULT '{}',
  badge text NOT NULL DEFAULT '',
  image text NOT NULL,
  alt text NOT NULL DEFAULT '',
  source text NOT NULL DEFAULT '',
  stock integer CHECK (stock IS NULL OR stock >= 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (image ~ '^https://')
);

CREATE TABLE IF NOT EXISTS public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  status text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'processing', 'completed', 'cancelled')),
  total_amount numeric(12, 2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  product_id text NOT NULL,
  product_name text NOT NULL,
  size text NOT NULL,
  quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 99),
  unit_price numeric(12, 2) NOT NULL CHECK (unit_price >= 0)
);

CREATE INDEX IF NOT EXISTS orders_created_at_idx ON public.orders (created_at DESC);
CREATE INDEX IF NOT EXISTS orders_status_idx ON public.orders (status);
CREATE INDEX IF NOT EXISTS order_items_order_id_idx ON public.order_items (order_id);

CREATE OR REPLACE FUNCTION public.current_staff_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT role
  FROM public.staff_members
  WHERE user_id = auth.uid()
$$;

CREATE OR REPLACE FUNCTION public.is_northwear_staff()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.current_staff_role() IN ('admin', 'staff')
$$;

CREATE OR REPLACE FUNCTION public.on_staff_signup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  invited_role text;
BEGIN
  SELECT role INTO invited_role
  FROM public.staff_invites
  WHERE email = lower(NEW.email)
  FOR UPDATE;

  IF invited_role IS NULL THEN
    RAISE EXCEPTION 'This email does not have a NORTH WEAR staff invitation.'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.staff_members (user_id, email, role)
  VALUES (NEW.id, lower(NEW.email), invited_role);

  DELETE FROM public.staff_invites
  WHERE email = lower(NEW.email);

  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS northwear_staff_signup ON auth.users;
CREATE TRIGGER northwear_staff_signup
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.on_staff_signup();

CREATE OR REPLACE FUNCTION public.place_order(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  created_order_id uuid;
  cart_item jsonb;
  item_product public.products%ROWTYPE;
  item_size text;
  item_quantity integer;
  order_total numeric(12, 2) := 0;
  line_items jsonb := '[]'::jsonb;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'The order items must be a JSON array.';
  END IF;

  IF jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 25 THEN
    RAISE EXCEPTION 'The order must contain between 1 and 25 items.';
  END IF;

  INSERT INTO public.orders DEFAULT VALUES
  RETURNING id INTO created_order_id;

  FOR cart_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    IF coalesce(cart_item->>'quantity', '') !~ '^[1-9][0-9]{0,1}$' THEN
      RAISE EXCEPTION 'Order quantity must be between 1 and 99.';
    END IF;

    item_quantity := (cart_item->>'quantity')::integer;
    item_size := cart_item->>'size';

    SELECT * INTO item_product
    FROM public.products
    WHERE id = cart_item->>'id'
      AND is_active = true
    FOR UPDATE;

    IF NOT FOUND OR item_product.price IS NULL THEN
      RAISE EXCEPTION 'The selected product is no longer available.';
    END IF;

    IF item_product.stock IS NOT NULL AND item_product.stock < item_quantity THEN
      RAISE EXCEPTION 'There is not enough stock to complete this order.';
    END IF;

    IF item_size IS NULL OR NOT item_size = ANY(item_product.sizes) THEN
      RAISE EXCEPTION 'The selected size is not available.';
    END IF;

    IF coalesce((
      SELECT sum(quantity)
      FROM public.order_items AS existing_item
      WHERE existing_item.order_id = created_order_id
        AND existing_item.product_id = item_product.id
        AND existing_item.size = item_size
    ), 0) + item_quantity > 99 THEN
      RAISE EXCEPTION 'The order cannot contain more than 99 units of one product size.';
    END IF;

    INSERT INTO public.order_items (order_id, product_id, product_name, size, quantity, unit_price)
    VALUES (created_order_id, item_product.id, item_product.name, item_size, item_quantity, item_product.price);

    line_items := line_items || jsonb_build_array(jsonb_build_object(
      'product_name', item_product.name,
      'size', item_size,
      'quantity', item_quantity,
      'unit_price', item_product.price
    ));

    IF item_product.stock IS NOT NULL THEN
      UPDATE public.products
      SET stock = stock - item_quantity,
          updated_at = now()
      WHERE id = item_product.id;
    END IF;

    order_total := order_total + item_product.price * item_quantity;
  END LOOP;

  UPDATE public.orders
  SET total_amount = order_total
  WHERE id = created_order_id;

  RETURN jsonb_build_object(
    'id', created_order_id,
    'total_amount', order_total,
    'items', line_items
  );
END
$$;

ALTER TABLE public.staff_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "staff can read active catalog" ON public.products;
CREATE POLICY "staff can read active catalog"
  ON public.products FOR SELECT TO anon, authenticated
  USING (is_active OR public.is_northwear_staff());

DROP POLICY IF EXISTS "staff can insert products" ON public.products;
CREATE POLICY "staff can insert products"
  ON public.products FOR INSERT TO authenticated
  WITH CHECK (public.is_northwear_staff());

DROP POLICY IF EXISTS "staff can update products" ON public.products;
CREATE POLICY "staff can update products"
  ON public.products FOR UPDATE TO authenticated
  USING (public.is_northwear_staff())
  WITH CHECK (public.is_northwear_staff());

DROP POLICY IF EXISTS "staff can read orders" ON public.orders;
CREATE POLICY "staff can read orders"
  ON public.orders FOR SELECT TO authenticated
  USING (public.is_northwear_staff());

DROP POLICY IF EXISTS "staff can update orders" ON public.orders;
CREATE POLICY "staff can update orders"
  ON public.orders FOR UPDATE TO authenticated
  USING (public.is_northwear_staff())
  WITH CHECK (public.is_northwear_staff());

DROP POLICY IF EXISTS "staff can read order items" ON public.order_items;
CREATE POLICY "staff can read order items"
  ON public.order_items FOR SELECT TO authenticated
  USING (public.is_northwear_staff());

DROP POLICY IF EXISTS "staff can read members" ON public.staff_members;
CREATE POLICY "staff can read members"
  ON public.staff_members FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.current_staff_role() = 'admin');

DROP POLICY IF EXISTS "admins can read invitations" ON public.staff_invites;
CREATE POLICY "admins can read invitations"
  ON public.staff_invites FOR SELECT TO authenticated
  USING (public.current_staff_role() = 'admin');

DROP POLICY IF EXISTS "admins can invite staff" ON public.staff_invites;
CREATE POLICY "admins can invite staff"
  ON public.staff_invites FOR INSERT TO authenticated
  WITH CHECK (public.current_staff_role() = 'admin' AND role = 'staff');

DROP POLICY IF EXISTS "admins can remove invitations" ON public.staff_invites;
CREATE POLICY "admins can remove invitations"
  ON public.staff_invites FOR DELETE TO authenticated
  USING (public.current_staff_role() = 'admin');

GRANT SELECT ON public.products TO anon, authenticated;
GRANT INSERT, UPDATE ON public.products TO authenticated;
GRANT SELECT ON public.orders TO authenticated;
GRANT UPDATE (status, updated_at) ON public.orders TO authenticated;
GRANT SELECT ON public.order_items, public.staff_members TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.staff_invites TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_staff_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_northwear_staff() TO anon, authenticated;
REVOKE ALL ON FUNCTION public.on_staff_signup() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.place_order(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_order(jsonb) TO anon, authenticated;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('product-images', 'product-images', true, 8000000, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
SET public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "anyone can view product images" ON storage.objects;
CREATE POLICY "anyone can view product images"
  ON storage.objects FOR SELECT TO anon, authenticated
  USING (bucket_id = 'product-images');

DROP POLICY IF EXISTS "staff can upload product images" ON storage.objects;
CREATE POLICY "staff can upload product images"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'product-images' AND public.is_northwear_staff());

DROP POLICY IF EXISTS "staff can update product images" ON storage.objects;
CREATE POLICY "staff can update product images"
  ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'product-images' AND public.is_northwear_staff())
  WITH CHECK (bucket_id = 'product-images' AND public.is_northwear_staff());

DROP POLICY IF EXISTS "staff can delete product images" ON storage.objects;
CREATE POLICY "staff can delete product images"
  ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'product-images' AND public.is_northwear_staff());
