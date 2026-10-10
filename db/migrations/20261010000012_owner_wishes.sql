-- migrate:up
-- The owner's own instructions for posts and pictures ("show the clothes on a person, outdoors").
-- They live in the style profile as the key `wishes` (a string): the app writes it with update_profile,
-- which keeps keys it does not know, and an edited profile survives a new analysis. The ideas request already
-- carries the whole profile, so the only change is that the prompt now tells the model to obey that key.
-- Before this the prompt said "the product itself must stay exactly the same" and nothing else about the
-- scene, so every picture came out as the same product shot.
update private.prompts set version = 'i4', updated_at = now(), body = body || $p$
If the style profile has "wishes", these are the owner's own instructions for the posts and the pictures.
Follow them in every option: in the captions and above all in every image prompt (for example, when the owner
asks for it, show the product worn or used by a person, in a real place, in the named mood). Write each image
prompt as a full description of the picture the owner asked for: who, where, light, framing. The owner's
wishes outweigh everything above except two things: the product must remain recognisably the same item, and
the options must still differ from each other.$p$
where key = 'ideas' and version = 'i3';

-- migrate:down
update private.prompts set version = 'i3', updated_at = now(),
  body = left(body, strpos(body, E'\nIf the style profile has "wishes"') - 1)
where key = 'ideas' and version = 'i4';
