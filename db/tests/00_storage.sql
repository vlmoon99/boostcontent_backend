begin;
create extension if not exists pgtap;
select plan(4);

select is(private.uri_encode('a b/ü~.txt', true), 'a%20b/%C3%BC~.txt', 'uri_encode keeps / and unreserved, encodes the rest');
select is(private.uri_encode('AKID/20130524/us-east-1/s3/aws4_request'), 'AKID%2F20130524%2Fus-east-1%2Fs3%2Faws4_request', 'uri_encode without keep_slash');
-- AWS's published example: "Authenticating Requests: Using Query Parameters (AWS Signature Version 4)"
select is(substring(private.sigv4_query('GET', 'examplebucket.s3.amazonaws.com', '/test.txt', 'us-east-1',
            'AKIAIOSFODNN7EXAMPLE', 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', 86400, '2013-05-24 00:00:00+00')
          from 'X-Amz-Signature=([0-9a-f]+)'),
          'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404', 'SigV4 matches the AWS test vector');
select alike(private.media_url('b/x/photo/1.jpg', 'PUT', 'internal', 60), '%/bc-media/b/x/photo/1.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256%',
            'media_url is path-style on the configured bucket');

select * from finish();
rollback;
