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
  customer_name text NOT NULL DEFAULT '',
  customer_phone text NOT NULL DEFAULT '',
  delivery_city text NOT NULL DEFAULT '',
  delivery_method text NOT NULL DEFAULT 'nova_poshta_branch' CHECK (delivery_method = 'nova_poshta_branch'),
  delivery_address text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS customer_name text NOT NULL DEFAULT '';
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS customer_phone text NOT NULL DEFAULT '';
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS delivery_city text NOT NULL DEFAULT '';
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS delivery_method text NOT NULL DEFAULT 'nova_poshta_branch'
  CHECK (delivery_method = 'nova_poshta_branch');
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS delivery_address text NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS public.custom_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  status text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'processing', 'completed', 'cancelled')),
  customer_name text NOT NULL CHECK (char_length(customer_name) BETWEEN 2 AND 100),
  customer_phone text NOT NULL CHECK (
    customer_phone ~ '^\+?[0-9 ()-]{9,19}$'
    AND length(regexp_replace(customer_phone, '[^0-9]', '', 'g')) BETWEEN 10 AND 13
  ),
  garment text NOT NULL CHECK (garment IN ('tee', 'hoodie', 'sweatshirt')),
  garment_color text NOT NULL CHECK (garment_color IN ('Чорний', 'Білий', 'Червоний', 'Сірий')),
  size text NOT NULL CHECK (size IN ('XS', 'S', 'M', 'L', 'XL', 'XXL', 'XXXL', 'XXXXL')),
  placement text NOT NULL CHECK (placement IN ('a6', 'front', 'back')),
  print_text text NOT NULL DEFAULT '' CHECK (char_length(print_text) <= 80),
  quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 99),
  image_path text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (image_path IS NULL OR image_path ~* ('^' || id::text || '/design\.(jpg|png|webp)$')),
  CHECK (char_length(print_text) > 0 OR image_path IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS public.order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  product_id text NOT NULL,
  product_name text NOT NULL,
  size text NOT NULL,
  color text NOT NULL DEFAULT '',
  quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 99),
  unit_price numeric(12, 2) NOT NULL CHECK (unit_price >= 0)
);

ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS color text NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS orders_created_at_idx ON public.orders (created_at DESC);
CREATE INDEX IF NOT EXISTS orders_status_idx ON public.orders (status);
CREATE INDEX IF NOT EXISTS order_items_order_id_idx ON public.order_items (order_id);
CREATE INDEX IF NOT EXISTS order_items_product_id_idx ON public.order_items (product_id);
CREATE INDEX IF NOT EXISTS custom_requests_created_at_idx ON public.custom_requests (created_at DESC);

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

DROP FUNCTION IF EXISTS public.place_order(jsonb);
CREATE OR REPLACE FUNCTION public.place_order(p_items jsonb, p_customer jsonb)
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
  item_color text;
  item_quantity integer;
  order_total numeric(12, 2) := 0;
  line_items jsonb := '[]'::jsonb;
  customer_name_value text;
  customer_phone_value text;
  delivery_city_value text;
  delivery_method_value text;
  delivery_address_value text;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'The order items must be a JSON array.';
  END IF;

  IF p_customer IS NULL OR jsonb_typeof(p_customer) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Customer and delivery details are required.';
  END IF;

  customer_name_value := coalesce(btrim(p_customer->>'name'), '');
  customer_phone_value := coalesce(btrim(p_customer->>'phone'), '');
  delivery_city_value := coalesce(btrim(p_customer->>'city'), '');
  delivery_method_value := p_customer->>'delivery_method';
  delivery_address_value := coalesce(btrim(p_customer->>'delivery_address'), '');

  IF length(customer_name_value) NOT BETWEEN 2 AND 100 THEN
    RAISE EXCEPTION 'Customer name must be between 2 and 100 characters.';
  END IF;

  IF customer_phone_value !~ '^\+?[0-9 ()-]{9,19}$'
     OR length(regexp_replace(customer_phone_value, '[^0-9]', '', 'g')) NOT BETWEEN 10 AND 13 THEN
    RAISE EXCEPTION 'Enter a valid contact phone number.';
  END IF;

  IF length(delivery_city_value) NOT BETWEEN 2 AND 80 THEN
    RAISE EXCEPTION 'Delivery city must be between 2 and 80 characters.';
  END IF;

  IF delivery_method_value IS DISTINCT FROM 'nova_poshta_branch' THEN
    RAISE EXCEPTION 'The selected delivery method is not supported.';
  END IF;

  IF length(delivery_address_value) NOT BETWEEN 2 AND 120 THEN
    RAISE EXCEPTION 'Nova Poshta branch or locker is required.';
  END IF;

  IF jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 25 THEN
    RAISE EXCEPTION 'The order must contain between 1 and 25 items.';
  END IF;

  INSERT INTO public.orders (
    customer_name, customer_phone, delivery_city, delivery_method, delivery_address
  )
  VALUES (
    customer_name_value, customer_phone_value, delivery_city_value, delivery_method_value, delivery_address_value
  )
  RETURNING id INTO created_order_id;

  FOR cart_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    IF coalesce(cart_item->>'quantity', '') !~ '^[1-9][0-9]{0,1}$' THEN
      RAISE EXCEPTION 'Order quantity must be between 1 and 99.';
    END IF;

    item_quantity := (cart_item->>'quantity')::integer;
    item_size := cart_item->>'size';
    item_color := coalesce(cart_item->>'color', '');

    IF length(item_color) > 40 THEN
      RAISE EXCEPTION 'The selected color is too long.';
    END IF;

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

    INSERT INTO public.order_items (order_id, product_id, product_name, size, color, quantity, unit_price)
    VALUES (created_order_id, item_product.id, item_product.name, item_size, item_color, item_quantity, item_product.price);

    line_items := line_items || jsonb_build_array(jsonb_build_object(
      'product_name', item_product.name,
      'size', item_size,
      'color', item_color,
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

CREATE OR REPLACE FUNCTION public.sync_order_stock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  item record;
  current_stock integer;
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  IF OLD.status <> 'cancelled' AND NEW.status = 'cancelled' THEN
    FOR item IN
      SELECT product_id, sum(quantity)::integer AS quantity
      FROM public.order_items
      WHERE order_id = NEW.id
      GROUP BY product_id
      ORDER BY product_id
    LOOP
      UPDATE public.products
      SET stock = stock + item.quantity,
          updated_at = now()
      WHERE id = item.product_id
        AND stock IS NOT NULL;
    END LOOP;
  ELSIF OLD.status = 'cancelled' AND NEW.status <> 'cancelled' THEN
    FOR item IN
      SELECT product_id, sum(quantity)::integer AS quantity
      FROM public.order_items
      WHERE order_id = NEW.id
      GROUP BY product_id
      ORDER BY product_id
    LOOP
      SELECT stock INTO current_stock
      FROM public.products
      WHERE id = item.product_id
      FOR UPDATE;

      IF FOUND AND current_stock IS NOT NULL THEN
        IF current_stock < item.quantity THEN
          RAISE EXCEPTION 'Insufficient stock to reactivate cancelled order.'
            USING ERRCODE = '23514';
        END IF;

        UPDATE public.products
        SET stock = stock - item.quantity,
            updated_at = now()
        WHERE id = item.product_id;
      END IF;
    END LOOP;
  END IF;

  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS northwear_order_stock_sync ON public.orders;
CREATE TRIGGER northwear_order_stock_sync
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.sync_order_stock();

CREATE OR REPLACE FUNCTION public.popular_products()
RETURNS TABLE(product_id text, units_sold bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT item.product_id, sum(item.quantity)::bigint AS units_sold
  FROM public.order_items AS item
  JOIN public.orders AS customer_order ON customer_order.id = item.order_id
  WHERE customer_order.status <> 'cancelled'
  GROUP BY item.product_id
  ORDER BY units_sold DESC, item.product_id
  LIMIT 6
$$;

ALTER TABLE public.staff_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.custom_requests ENABLE ROW LEVEL SECURITY;

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

DROP POLICY IF EXISTS "anyone can submit custom requests" ON public.custom_requests;
CREATE POLICY "anyone can submit custom requests"
  ON public.custom_requests FOR INSERT TO anon, authenticated
  WITH CHECK (status = 'new');

DROP POLICY IF EXISTS "staff can read custom requests" ON public.custom_requests;
CREATE POLICY "staff can read custom requests"
  ON public.custom_requests FOR SELECT TO authenticated
  USING (public.is_northwear_staff());

DROP POLICY IF EXISTS "staff can update custom requests" ON public.custom_requests;
CREATE POLICY "staff can update custom requests"
  ON public.custom_requests FOR UPDATE TO authenticated
  USING (public.is_northwear_staff())
  WITH CHECK (public.is_northwear_staff());

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
GRANT INSERT ON public.custom_requests TO anon, authenticated;
GRANT SELECT ON public.custom_requests TO authenticated;
GRANT UPDATE (status, updated_at) ON public.custom_requests TO authenticated;
GRANT SELECT ON public.order_items, public.staff_members TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.staff_invites TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_staff_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_northwear_staff() TO anon, authenticated;
REVOKE ALL ON FUNCTION public.on_staff_signup() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.place_order(jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_order(jsonb, jsonb) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.sync_order_stock() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.popular_products() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.popular_products() TO anon, authenticated;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('product-images', 'product-images', true, 8000000, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
SET public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('custom-designs', 'custom-designs', false, 8000000, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
SET public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "customers can upload custom designs" ON storage.objects;
CREATE POLICY "customers can upload custom designs"
  ON storage.objects FOR INSERT TO anon, authenticated
  WITH CHECK (
    bucket_id = 'custom-designs'
    AND name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/design\.(jpg|png|webp)$'
  );

DROP POLICY IF EXISTS "staff can view custom designs" ON storage.objects;
CREATE POLICY "staff can view custom designs"
  ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'custom-designs' AND public.is_northwear_staff());

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
